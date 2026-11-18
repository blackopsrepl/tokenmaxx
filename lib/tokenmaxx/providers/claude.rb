# frozen_string_literal: true

require "json"

module TokenMaxx
  module Providers
    module Claude
      DEFAULT_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" # gitleaks:allow

      module_function

      TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
      LOGIN_HINT = "Run `claude` and `/login` to sign in again."

      def fetch(config)
        source = config[:source] == "cli" ? "claude" : "oauth"
        access_token, credentials = Core::OAuthRenewal.resolve(credential_store, hold_dir: Core::OAuthRenewal.hold_dir(config))

        response = Core::Http.request(
          "GET",
          "https://api.anthropic.com/api/oauth/usage",
          headers: {
            "Authorization" => "Bearer #{access_token}",
            "Accept" => "application/json",
            "Content-Type" => "application/json",
            "anthropic-beta" => "oauth-2025-04-20",
            "User-Agent" => "claude-code/2.1.0"
          }
        )

        raise "Claude OAuth request unauthorized. #{LOGIN_HINT}" if response.status == 401
        raise "Claude OAuth error: HTTP #{response.status}" unless response.status.between?(200, 299)

        payload = Core::Http.parse_json(response)
        usage = {
          primary: make_window(payload[:five_hour], 300),
          secondary: make_window(payload[:seven_day], 10_080),
          tertiary: make_window(payload[:seven_day_sonnet] || payload[:seven_day_opus], 10_080),
          providerCost: make_extra_usage(payload[:extra_usage]),
          updatedAt: Time.now.utc.iso8601,
          identity: {
            providerID: "claude",
            loginMethod: claude_login_method(credentials.dig(:claudeAiOauth, :rateLimitTier))
          }
        }

        {
          provider: "claude",
          source: source,
          usage: usage,
          notes: []
        }
      rescue StandardError => e
        {
          provider: "claude",
          source: source,
          notes: [],
          error: e.message
        }
      end

      def claude_dir
        File.join(Dir.home, ".claude")
      end

      # Claude Code's own credential file and the locks its renewal takes:
      # proper-lockfile on `.oauth_refresh.lock` and on the legacy `<dir>.lock`,
      # plus the flock Hermes takes on `.credentials.lock` for the same file.
      def credential_store
        dir = claude_dir
        real_dir = File.directory?(dir) ? File.realpath(dir) : dir
        Core::OAuthRenewal::Store.new(
          id: "claude",
          label: "Claude",
          path: File.join(dir, ".credentials.json"),
          locks: [
            { kind: :mkdir, path: File.join(dir, ".oauth_refresh.lock") },
            { kind: :mkdir, path: "#{real_dir}.lock" },
            { kind: :flock, path: File.join(dir, ".credentials.lock") }
          ],
          rotating: true,
          login_hint: LOGIN_HINT,
          read_credential: ->(doc) { read_credential(doc) },
          request: ->(credential, doc) { refresh_request(credential, doc) },
          apply: ->(doc, body, issued_at) { apply_refresh(doc, body, issued_at) }
        )
      end

      def read_credential(doc)
        oauth = doc[:claudeAiOauth] || {}
        expires_at = oauth[:expiresAt] ? Time.at(oauth[:expiresAt].to_f / 1000.0) : nil
        {
          access_token: oauth[:accessToken].to_s.strip,
          refresh_token: oauth[:refreshToken].to_s,
          expires_at: expires_at
        }
      end

      # Same request Claude Code sends: JSON body with the stored scopes.
      def refresh_request(credential, doc)
        scopes = Array(doc.dig(:claudeAiOauth, :scopes)).map(&:to_s).reject(&:empty?)
        body = {
          grant_type: "refresh_token",
          refresh_token: credential[:refresh_token],
          client_id: ENV["TOKENMAXX_CLAUDE_OAUTH_CLIENT_ID"] || DEFAULT_CLIENT_ID
        }
        body[:scope] = scopes.join(" ") unless scopes.empty?
        { url: TOKEN_URL, json: body }
      end

      # Rotates the token triple and keeps every other field Claude Code wrote.
      def apply_refresh(doc, body, issued_at)
        issued_ms = (issued_at.to_f * 1000).to_i
        oauth = (doc[:claudeAiOauth] || {}).merge(
          accessToken: body[:access_token].to_s,
          refreshToken: body[:refresh_token] || doc.dig(:claudeAiOauth, :refreshToken),
          expiresAt: issued_ms + (body[:expires_in] || 3600).to_i * 1000
        )
        if body[:refresh_token_expires_in]
          oauth[:refreshTokenExpiresAt] = issued_ms + body[:refresh_token_expires_in].to_i * 1000
        end
        oauth[:scopes] = body[:scope].to_s.split if body[:scope].is_a?(String) && !body[:scope].strip.empty?
        doc.merge(claudeAiOauth: oauth)
      end

      def make_window(window, minutes)
        utilization = window&.dig(:utilization)
        return nil if utilization.nil?

        {
          usedPercent: utilization.to_f,
          windowMinutes: minutes,
          resetsAt: window[:resets_at],
          resetDescription: nil
        }
      end

      def make_extra_usage(extra)
        return nil unless extra&.dig(:is_enabled)
        return nil if extra[:used_credits].nil? || extra[:monthly_limit].nil?

        {
          used: extra[:used_credits].to_f / 100.0,
          limit: extra[:monthly_limit].to_f / 100.0,
          currencyCode: extra[:currency].to_s.strip.empty? ? "USD" : extra[:currency].to_s.strip,
          period: "Monthly",
          updatedAt: Time.now.utc.iso8601
        }
      end

      def claude_login_method(rate_limit_tier)
        tier = rate_limit_tier.to_s.strip.downcase
        return nil if tier.empty?
        return "Claude Max" if tier.include?("max")
        return "Claude Pro" if tier.include?("pro")
        return "Claude Team" if tier.include?("team")
        return "Claude Enterprise" if tier.include?("enterprise")

        nil
      end
    end
  end
end
