# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "socket"
require "time"

module TokenMaxx
  module Core
    # Renews OAuth access tokens stored in another client's credential file
    # (Claude Code, Gemini CLI) without ever spending a refresh token twice.
    #
    # The protocol follows the vendor rules for rotating refresh tokens: a used
    # refresh token that is sent again more than 30 seconds after its first use
    # revokes the whole login. So every renewal
    #
    # - starts 5 minutes before the access token expires, like the CLIs do;
    # - runs under the same cross-process locks the owning CLI takes, then
    #   re-reads the file and adopts a renewal another client already made;
    # - records a hold on the refresh token before it leaves the process, so a
    #   request whose outcome is unknown is never replayed later by any
    #   TokenMaxx process;
    # - resends a dropped request at most once, and only inside the 30s window;
    # - writes the rotated pair atomically before the new access token is used.
    #
    # Providers describe their credential file with a Store; nothing here knows
    # about a specific vendor.
    module OAuthRenewal
      REFRESH_MARGIN_SECONDS = 300
      RESEND_WINDOW_SECONDS = 30
      OPEN_TIMEOUT_SECONDS = 10
      READ_TIMEOUT_SECONDS = 12
      WRITE_ATTEMPTS = 5

      # The request never left this process: retrying later is safe.
      NOT_SENT_ERRORS = [
        Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
        Errno::ENETUNREACH, Errno::EADDRNOTAVAIL
      ].freeze

      class LoginExpired < StandardError; end
      class RenewalFailed < StandardError; end

      # id:              stable key for hold bookkeeping ("claude", "gemini").
      # label:           human name used in messages.
      # path:            credential file.
      # locks:           CredentialLocks specs shared with the owning CLI.
      # rotating:        true when every refresh replaces the refresh token.
      # login_hint:      how the user signs in again.
      # read_credential: ->(doc) { { access_token:, refresh_token:, expires_at: Time|nil } }
      # request:         ->(credential, doc) { { url:, json: | form: } }
      # apply:           ->(doc, body, issued_at) { new doc with the renewed tokens }
      Store = Struct.new(:id, :label, :path, :locks, :rotating, :login_hint,
                         :read_credential, :request, :apply, keyword_init: true)

      module_function

      # Providers receive their own config entry; the fetch path adds the
      # runtime state dir so holds live with the rest of TokenMaxx state.
      def hold_dir(provider_config)
        File.expand_path(provider_config[:stateDir] || Config.default_config.dig(:runtime, :stateDir))
      end

      # Returns [access_token, credential_document], renewing when needed.
      def resolve(store, hold_dir:, now: Time.now, http: Http, sleeper: ->(seconds) { sleep(seconds) },
                  clock: -> { ::Process.clock_gettime(::Process::CLOCK_MONOTONIC) })
        doc = read_document(store)
        credential = store.read_credential.call(doc)
        return [credential[:access_token], doc] if fresh?(credential, now)

        begin
          CredentialLocks.with_locks(store.locks, sleeper: sleeper) do
            doc = read_document(store)
            latest = store.read_credential.call(doc)
            return [latest[:access_token], doc] if fresh?(latest, now)

            renew(store, doc, latest, hold_dir: hold_dir, http: http, sleeper: sleeper, clock: clock)
          end
        rescue CredentialLocks::Busy
          return [credential[:access_token], doc] if usable?(credential, now)

          raise RenewalFailed, "#{store.label} credentials are being renewed by another client; retrying next refresh."
        end
      end

      def fresh?(credential, now)
        return false if credential[:access_token].to_s.empty?
        return true if credential[:expires_at].nil?

        credential[:expires_at] - now > REFRESH_MARGIN_SECONDS
      end

      def usable?(credential, now)
        return false if credential[:access_token].to_s.empty?

        credential[:expires_at].nil? || credential[:expires_at] > now
      end

      SPENT_NOTE = "its refresh token may already be spent, and TokenMaxx will not resend it"

      def renew(store, doc, credential, hold_dir:, http:, sleeper:, clock:)
        refresh_token = credential[:refresh_token].to_s
        raise sign_in_required(store, "no refresh token is stored") if refresh_token.empty?

        fingerprint = fingerprint(refresh_token)
        holds = HoldBook.new(hold_dir, store.id)
        held_reason = holds.reason(fingerprint)
        raise sign_in_required(store, held_reason) if held_reason

        # The hold is on disk before the token leaves the process; only an
        # answer proving the token unused or rotated takes it off.
        holds.add(fingerprint, "a renewal was interrupted, so #{SPENT_NOTE}") if store.rotating
        issued_at = Time.now
        response = exchange(store, doc, credential, http: http, clock: clock)
        if response.is_a?(String)
          holds.add(fingerprint, response) if store.rotating
          raise sign_in_required(store, response)
        end

        if response == :not_sent
          holds.remove(fingerprint)
          raise RenewalFailed, "#{store.label} token endpoint unreachable; retrying next refresh."
        end

        if invalid_grant?(response)
          reason = "the refresh token was rejected (expired, revoked, or already used)"
          holds.add(fingerprint, reason) if store.rotating
          raise sign_in_required(store, reason)
        end

        unless response.status == 200
          holds.remove(fingerprint)
          raise RenewalFailed, "#{store.label} token renewal failed with HTTP #{response.status}#{error_suffix(response)}."
        end

        body = Http.parse_json(response)
        if body[:access_token].to_s.empty?
          raise RenewalFailed, "#{store.label} token renewal returned no access token." unless store.rotating

          reason = "the renewal answer carried no access token, so #{SPENT_NOTE}"
          holds.add(fingerprint, reason)
          raise sign_in_required(store, reason)
        end

        renewed = store.apply.call(doc, body, issued_at)
        begin
          write_document(store, renewed, sleeper)
        rescue SystemCallError, IOError => e
          reason = "the renewed tokens could not be saved (#{e.message}), so #{SPENT_NOTE}"
          holds.add(fingerprint, reason) if store.rotating
          raise sign_in_required(store, reason)
        end
        holds.remove(fingerprint)
        [body[:access_token].to_s, renewed]
      end

      # Sends the refresh request, resending once at most when the first
      # answer was lost. Returns the response, :not_sent, or a String naming
      # why the refresh token's fate is unknown.
      def exchange(store, doc, credential, http:, clock:)
        started = clock.call
        first = send_once(store, doc, credential, http)
        return first if first.is_a?(Http::Response) && !lost?(first)
        return :not_sent if first == :not_sent
        # Non-rotating refresh tokens survive any number of uses: report the
        # failure and let the next refresh cycle try again.
        return first.is_a?(Http::Response) ? first : :not_sent unless store.rotating
        # A timed-out request may still be running server-side.
        return "a renewal timed out, so #{SPENT_NOTE}" if first == :timeout
        return "a renewal got no usable answer, so #{SPENT_NOTE}" if clock.call - started > RESEND_WINDOW_SECONDS

        second = send_once(store, doc, credential, http)
        return second if second.is_a?(Http::Response) && second.status == 200

        "two renewals got no usable answer, so #{SPENT_NOTE}"
      end

      def sign_in_required(store, reason)
        LoginExpired.new("#{store.label} login needs a new sign-in: #{reason}. #{store.login_hint}")
      end

      def send_once(store, doc, credential, http)
        request = store.request.call(credential, doc)
        http.request(
          "POST",
          request.fetch(:url),
          json: request[:json],
          form: request[:form],
          headers: request.fetch(:headers, {}),
          open_timeout: OPEN_TIMEOUT_SECONDS,
          read_timeout: READ_TIMEOUT_SECONDS
        )
      rescue *NOT_SENT_ERRORS
        :not_sent
      rescue Net::ReadTimeout
        :timeout
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::WriteTimeout, Net::HTTPBadResponse
        :lost
      end

      # A 5xx can follow a refresh that took effect. A 503 with retry-after in
      # the API error format is a refusal that left the refresh token unused.
      def lost?(response)
        return false unless response.is_a?(Http::Response)
        return false if response.status < 500

        paused = response.status == 503 &&
                 Http.parse_json(response)[:type] == "error" &&
                 response.headers.keys.any? { |key| key.to_s.casecmp?("retry-after") }
        !paused
      end

      def invalid_grant?(response)
        response.status.between?(400, 499) && Http.parse_json(response)[:error].to_s == "invalid_grant"
      end

      def error_suffix(response)
        code = Http.parse_json(response)[:error]
        code.is_a?(String) && !code.empty? ? " (#{code})" : ""
      end

      def fingerprint(refresh_token)
        Digest::SHA256.hexdigest(refresh_token)[0, 32]
      end

      def read_document(store)
        JSON.parse(File.read(store.path), symbolize_names: true)
      rescue Errno::ENOENT
        raise sign_in_required(store, "no credentials at #{store.path}")
      rescue JSON::ParserError
        raise RenewalFailed, "#{store.label} credentials at #{store.path} are not valid JSON."
      end

      # Atomic replace in the same directory, owner-only, synced before rename.
      # A failed write is retried; the refresh is never repeated.
      def write_document(store, doc, sleeper)
        attempts = 0
        begin
          attempts += 1
          atomic_write(store.path, doc)
        rescue SystemCallError, IOError
          raise if attempts >= WRITE_ATTEMPTS

          sleeper.call(0.2 * attempts)
          retry
        end
      end

      def atomic_write(path, doc)
        temp_path = "#{path}.tokenmaxx.#{::Process.pid}.tmp"
        File.open(temp_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write("#{JSON.pretty_generate(doc)}\n")
          file.flush
          file.fsync
        end
        File.rename(temp_path, path)
      ensure
        FileUtils.rm_f(temp_path) if temp_path && File.exist?(temp_path)
      end

      # Fingerprints of refresh tokens whose renewal outcome is unknown. A hold
      # is written before the token leaves the process, so a crash mid-request
      # keeps it. Only a different refresh token in the file (a new login or a
      # renewal by another client) gets past it.
      class HoldBook
        def initialize(dir, id)
          @path = File.join(dir, "oauth-holds", "#{id}.json")
        end

        def reason(fingerprint)
          entry = entries[fingerprint]
          entry.is_a?(Hash) ? entry["reason"].to_s : nil
        end

        def add(fingerprint, reason)
          write(entries.merge(fingerprint => { "reason" => reason, "since" => Time.now.utc.iso8601 }))
        end

        def remove(fingerprint)
          current = entries
          return unless current.key?(fingerprint)

          current.delete(fingerprint)
          write(current)
        end

        private

        def entries
          parsed = JSON.parse(File.read(@path))
          parsed.is_a?(Hash) ? parsed : {}
        rescue Errno::ENOENT, JSON::ParserError
          {}
        end

        def write(payload)
          FileUtils.mkdir_p(File.dirname(@path))
          OAuthRenewal.atomic_write(@path, payload)
        end
      end
    end
  end
end
