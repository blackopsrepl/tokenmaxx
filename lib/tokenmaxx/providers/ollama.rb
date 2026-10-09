# frozen_string_literal: true

require "json"
require "time"

module TokenMaxx
  module Providers
    # Ollama Cloud account allowance. Ollama exposes an authenticated balance
    # endpoint at ollama.com/api/balance (Bearer API key). Plans migrated to
    # monthly credits report the included allowance in USD with its reset
    # period:
    #
    #   { "included": { "balance_usd": 17.35, "allowance_usd": 60,
    #                   "period": { "from": "...", "until": "..." } },
    #     "purchased": { "balance_usd": 0 } }
    #
    # Legacy plans with session and weekly limits instead report
    # included.session and included.weekly as 0..100 remaining percentages
    # with a resets_at timestamp. The two shapes are mutually exclusive per
    # account, so a missing shape simply yields no window. Usage history
    # lives in /api/usage?range=24h|7d|30d; it is an accounting time series
    # and carries no allowance data, so the quota meter never reads it. The
    # balance endpoint does not return the plan tier, so the provider
    # identity reports the fixed "Ollama Cloud" login method. Local usage
    # comes from the OpenCode usage database.
    module Ollama
      BALANCE_URL = "https://ollama.com/api/balance"
      SESSION_MINUTES = 300
      WEEKLY_MINUTES = 10_080
      MONTHLY_MINUTES = 43_200

      module_function

      def fetch(_config)
        source = "ollama-cloud"
        key = resolve_api_key
        raise "Ollama Cloud API key not found. Set OLLAMA_API_KEY or add an ollama-cloud entry to #{auth_path}." if key.to_s.strip.empty?

        response = Core::Http.request(
          "GET",
          BALANCE_URL,
          headers: {
            "Authorization" => "Bearer #{key}",
            "Accept" => "application/json",
            "User-Agent" => "tokenmaxx-linux/1.0"
          }
        )
        raise "Ollama Cloud balance request failed with HTTP #{response.status}." unless response.status.between?(200, 299)

        payload = Core::Http.parse_json(response)
        included = payload[:included]
        raise "Ollama Cloud balance response did not include an allowance." unless included.is_a?(Hash)

        monthly = monthly_window(included)
        session = remaining_window(included[:session], SESSION_MINUTES, "5-hour", "5h")
        weekly = remaining_window(included[:weekly], WEEKLY_MINUTES, "Weekly", "W")
        raise "Ollama Cloud balance response did not include a usable allowance." if monthly.nil? && session.nil? && weekly.nil?

        {
          provider: "ollama",
          source: source,
          usage: {
            primary: monthly || session,
            secondary: monthly ? nil : weekly,
            updatedAt: Time.now.utc.iso8601,
            identity: {
              providerID: "ollama",
              loginMethod: "Ollama Cloud"
            }
          },
          notes: purchased_notes(payload[:purchased])
        }
      rescue StandardError => e
        {
          provider: "ollama",
          source: source,
          notes: [],
          error: e.message
        }
      end

      def monthly_window(included)
        balance = included[:balance_usd]
        allowance = included[:allowance_usd]
        return nil if balance.nil? || allowance.nil? || allowance.to_f <= 0

        period = included[:period].is_a?(Hash) ? included[:period] : {}
        {
          label: "Monthly",
          shortLabel: "mo",
          usedPercent: clamp((1.0 - balance.to_f / allowance.to_f) * 100.0, 0.0, 100.0),
          windowMinutes: period_minutes(period) || MONTHLY_MINUTES,
          resetsAt: valid_reset_time(period[:until]),
          resetDescription: nil
        }
      end

      def remaining_window(window, minutes, label, short_label)
        return nil unless window.is_a?(Hash) && !window[:remaining_percent].nil?

        {
          label: label,
          shortLabel: short_label,
          usedPercent: clamp(100.0 - window[:remaining_percent].to_f, 0.0, 100.0),
          windowMinutes: minutes,
          resetsAt: valid_reset_time(window[:resets_at]),
          resetDescription: nil
        }
      end

      def purchased_notes(purchased)
        balance = purchased.is_a?(Hash) ? purchased[:balance_usd] : nil
        return [] if balance.nil? || balance.to_f <= 0

        ["Includes $#{format('%.2f', balance.to_f)} of purchased credits."]
      end

      def period_minutes(period)
        from = parse_time(period[:from])
        until_time = parse_time(period[:until])
        return nil if from.nil? || until_time.nil?

        minutes = ((until_time - from) / 60.0).round
        minutes.positive? ? minutes : nil
      end

      def parse_time(value)
        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def valid_reset_time(value)
        time = parse_time(value)
        return nil if time.nil? || time.year < 2000

        time.utc.iso8601
      end

      def resolve_api_key
        [ENV["OLLAMA_API_KEY"], opencode_auth_key].find { |value| value && !value.strip.empty? }&.strip
      end

      def opencode_auth_key
        return nil unless File.file?(auth_path)

        parsed = JSON.parse(File.read(auth_path), symbolize_names: true)
        entry = parsed[:"ollama-cloud"]
        key = entry && entry[:key]
        key.to_s.strip.empty? ? nil : key.to_s.strip
      rescue JSON::ParserError
        nil
      end

      def auth_path
        ENV["TOKENMAXX_OPENCODE_AUTH"] || File.join(Dir.home, ".local", "share", "opencode", "auth.json")
      end

      def clamp(value, min, max)
        [[value.to_f, min].max, max].min
      end
    end
  end
end
