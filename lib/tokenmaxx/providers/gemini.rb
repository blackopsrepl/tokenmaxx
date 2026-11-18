# frozen_string_literal: true

require "base64"
require "json"
require "time"

module TokenMaxx
  module Providers
    module Gemini
      module_function

      def fetch(config)
        source = config[:source] == "cli" ? "cli" : "api"
        home = Dir.home
        settings_path = File.join(home, ".gemini", "settings.json")
        creds_path = File.join(home, ".gemini", "oauth_creds.json")
        notes = []

        settings = load_json(settings_path)
        auth_type = gemini_auth_type(settings)
        if unsupported_quota_auth_type?(auth_type)
          raise "Gemini auth type #{auth_type} is not supported for quota. Log in with Google through Gemini CLI." unless File.file?(creds_path)

          notes << "Gemini CLI selected #{auth_type}; using OAuth credentials for Code Assist quota."
        end

        access_token, creds = Core::OAuthRenewal.resolve(
          credential_store(creds_path, Core::OAuthRenewal.hold_dir(config)),
          hold_dir: Core::OAuthRenewal.hold_dir(config)
        )
        claims = decode_jwt_claims(creds[:id_token])
        code_assist = load_code_assist(access_token)
        project_id = extract_project_id(code_assist) || discover_project_id(access_token)
        quota = load_quota(access_token, project_id)

        meters = quota_meters(Array(quota[:buckets]))
        raise "Gemini quota response did not include model buckets." if meters.empty?

        usage = {
          meters: meters,
          updatedAt: Time.now.utc.iso8601,
          identity: {
            providerID: "gemini",
            accountEmail: claims[:email].is_a?(String) ? claims[:email] : nil,
            loginMethod: gemini_plan(code_assist.dig(:currentTier, :id), claims[:hd])
          }
        }

        {
          provider: "gemini",
          source: source,
          usage: usage,
          notes: notes
        }
      rescue StandardError => e
        {
          provider: "gemini",
          source: source,
          notes: [],
          error: e.message
        }
      end

      LOGIN_HINT = "Run `gemini` and sign in with Google again."
      TOKEN_URL = "https://oauth2.googleapis.com/token"

      # Gemini CLI takes no lock on oauth_creds.json, so the lock only
      # serializes TokenMaxx processes. Google refresh tokens do not rotate.
      def credential_store(creds_path, hold_dir)
        Core::OAuthRenewal::Store.new(
          id: "gemini",
          label: "Gemini",
          path: creds_path,
          locks: [{ kind: :flock, path: File.join(hold_dir, "locks", "gemini-oauth.lock") }],
          rotating: false,
          login_hint: LOGIN_HINT,
          read_credential: ->(doc) { read_credential(doc) },
          request: ->(credential, _doc) { refresh_request(credential) },
          apply: ->(doc, body, issued_at) { apply_refresh(doc, body, issued_at) }
        )
      end

      def read_credential(doc)
        expiry = doc[:expiry_date].to_i
        {
          access_token: doc[:access_token].to_s,
          refresh_token: doc[:refresh_token].to_s,
          expires_at: expiry.zero? ? nil : Time.at(expiry / 1000.0)
        }
      end

      def refresh_request(credential)
        oauth_client = find_oauth_client
        raise Core::OAuthRenewal::RenewalFailed, "Could not find Gemini CLI OAuth client metadata for token refresh." unless oauth_client

        {
          url: TOKEN_URL,
          form: {
            client_id: oauth_client[:clientId],
            client_secret: oauth_client[:clientSecret],
            refresh_token: credential[:refresh_token],
            grant_type: "refresh_token"
          }
        }
      end

      def apply_refresh(doc, body, issued_at)
        renewed = doc.merge(
          access_token: body[:access_token].to_s,
          expiry_date: (issued_at.to_f * 1000).to_i + (body[:expires_in] || 3600).to_i * 1000
        )
        %i[id_token refresh_token scope token_type].each do |key|
          renewed[key] = body[key] if body[key]
        end
        renewed
      end

      def load_code_assist(access_token)
        response = Core::Http.request(
          "POST",
          "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
          headers: { "Authorization" => "Bearer #{access_token}" },
          json: { metadata: { ideType: "GEMINI_CLI", pluginType: "GEMINI" } }
        )
        return {} unless response.status.between?(200, 299)

        Core::Http.parse_json(response)
      end

      def load_quota(access_token, project_id)
        response = Core::Http.request(
          "POST",
          "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
          headers: { "Authorization" => "Bearer #{access_token}" },
          json: project_id ? { project: project_id } : {}
        )
        raise http_error_message("Gemini quota request", response) unless response.status.between?(200, 299)

        Core::Http.parse_json(response)
      end

      def http_error_message(context, response)
        error = Core::Http.parse_json(response)[:error]
        error = {} unless error.is_a?(Hash)
        message = error[:message].to_s.strip
        reason = Array(error[:details]).filter_map { |detail| detail[:reason] }.first
        reason = error[:status].to_s.strip if reason.to_s.empty?

        text = "#{context} failed with HTTP #{response.status}"
        text += ": #{message}" unless message.empty?
        text += " (#{reason})" unless reason.to_s.empty?
        text
      end

      def discover_project_id(access_token)
        response = Core::Http.request(
          "GET",
          "https://cloudresourcemanager.googleapis.com/v1/projects",
          headers: { "Authorization" => "Bearer #{access_token}" }
        )
        return nil unless response.status.between?(200, 299)

        payload = Core::Http.parse_json(response)
        Array(payload[:projects]).each do |project|
          project_id = project[:projectId]
          next unless project_id

          return project_id if project_id.start_with?("gen-lang-client")
          return project_id if project.dig(:labels, :"generative-language")
        end

        nil
      end

      def extract_project_id(response)
        project = response[:cloudaicompanionProject]
        return project if project.is_a?(String)
        return nil unless project.is_a?(Hash)

        project[:id] || project[:projectId]
      end

      def quota_meters(buckets)
        buckets.filter_map do |bucket|
          model_id = bucket[:modelId].to_s
          next if model_id.empty? || bucket[:remainingFraction].nil?

          percent_left = clamp(bucket[:remainingFraction].to_f * 100.0, 0.0, 100.0)
          {
            key: "model:#{model_id}",
            label: model_id,
            shortLabel: model_id.sub(/\Agemini-/, ""),
            modelId: model_id,
            usedPercent: clamp(100.0 - percent_left, 0.0, 100.0),
            remainingPercent: percent_left,
            windowMinutes: nil,
            resetsAt: valid_reset_time(bucket[:resetTime]),
            resetDescription: nil
          }
        end
      end

      def quota_to_window(quota)
        {
          usedPercent: [0, 100 - quota[:percentLeft].to_f].max,
          windowMinutes: nil,
          resetsAt: quota[:resetTime],
          resetDescription: nil
        }
      end

      def valid_reset_time(value)
        return nil if value.to_s.empty?

        time = Time.parse(value.to_s)
        return nil if time.year <= 2000

        time.utc.iso8601
      rescue ArgumentError
        nil
      end

      def clamp(value, min, max)
        [[value.to_f, min].max, max].min
      end

      def gemini_plan(tier_id, hosted_domain)
        return "Paid" if tier_id == "standard-tier"
        return "Workspace" if tier_id == "free-tier" && hosted_domain.is_a?(String) && !hosted_domain.empty?
        return "Free" if tier_id == "free-tier"
        return "Legacy" if tier_id == "legacy-tier"

        nil
      end

      def gemini_auth_type(settings)
        settings[:selectedAuthType].to_s.strip.empty? ? settings[:authType].to_s.strip : settings[:selectedAuthType].to_s.strip
      end

      def unsupported_quota_auth_type?(auth_type)
        normalized = auth_type.to_s.downcase
        normalized.include?("api-key") || normalized.include?("vertex")
      end

      def decode_jwt_claims(token)
        return {} unless token

        parts = token.split(".")
        return {} if parts.length < 2

        payload = parts[1]
        payload = payload + ("=" * ((4 - payload.length % 4) % 4))
        JSON.parse(Base64.urlsafe_decode64(payload), symbolize_names: true)
      rescue ArgumentError, JSON::ParserError
        {}
      end

      def find_oauth_client
        oauth_paths.each do |path|
          client = read_oauth_client(path)
          return client if client
        end

        nil
      end

      def oauth_paths
        candidates = [
          ENV["GEMINI_CLI_PATH"],
          Core::Process.executable_path("gemini"),
          "/usr/bin/gemini",
          "/usr/local/bin/gemini",
          File.join(Dir.home, ".bun", "bin", "gemini")
        ].compact.uniq

        candidates.flat_map { |candidate| oauth_paths_for_cli(candidate) }.uniq
      end

      def oauth_paths_for_cli(candidate)
        paths = [candidate]
        resolved = realpath(candidate)
        paths << resolved if resolved

        paths.flat_map do |path|
          legacy_oauth_paths(path) + bundled_oauth_paths(path)
        end
      end

      def legacy_oauth_paths(path)
        bin_dir = File.dirname(path)
        base_dir = File.dirname(bin_dir)
        [
          File.join(base_dir, "libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
          File.join(base_dir, "lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
          File.join(base_dir, "share/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
          File.join(base_dir, "../gemini-cli-core/dist/src/code_assist/oauth2.js"),
          File.join(base_dir, "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js")
        ]
      end

      def bundled_oauth_paths(path)
        root = gemini_package_root(path)
        return [] unless root

        [
          File.join(root, "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"),
          File.join(root, "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.ts"),
          *Dir.glob(File.join(root, "bundle", "chunk-*.js")).sort
        ]
      end

      def gemini_package_root(path)
        current = File.directory?(path) ? path : File.dirname(path)
        loop do
          package_path = File.join(current, "package.json")
          return current if gemini_package_json?(package_path)

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      def gemini_package_json?(path)
        return false unless File.file?(path)

        JSON.parse(File.read(path))["name"] == "@google/gemini-cli"
      rescue JSON::ParserError
        false
      end

      def read_oauth_client(path)
        return nil unless File.file?(path)

        content = File.read(path)
        client_id = content[/OAUTH_CLIENT_ID\s*=\s*['"]([\w\-.]+)['"]/, 1]
        client_secret = content[/OAUTH_CLIENT_SECRET\s*=\s*['"]([\w-]+)['"]/, 1]
        return nil unless client_id && client_secret

        { clientId: client_id, clientSecret: client_secret }
      end

      def realpath(path)
        File.realpath(path)
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
        nil
      end

      def load_json(path)
        JSON.parse(File.read(path), symbolize_names: true)
      end
    end
  end
end
