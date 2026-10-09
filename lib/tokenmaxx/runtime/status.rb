# frozen_string_literal: true

require "time"

module TokenMaxx
  module Runtime
    module Status
      STATUSPAGE_COMPONENT_STATES = {
        "operational" => "ok",
        "degraded_performance" => "degraded",
        "partial_outage" => "outage",
        "major_outage" => "outage",
        "under_maintenance" => "degraded"
      }.freeze

      STATUSPAGE_INDICATORS = {
        "none" => "ok",
        "minor" => "degraded",
        "major" => "outage",
        "critical" => "outage"
      }.freeze

      GOOGLE_STATES = {
        "AVAILABLE" => "ok",
        "SERVICE_INFORMATION" => "degraded",
        "SERVICE_DISRUPTION" => "degraded",
        "SERVICE_OUTAGE" => "outage"
      }.freeze

      module_function

      def read_cache(config)
        State.read_status(config)
      end

      def refresh_if_due(config, force: false, now: Time.now.utc)
        cached = read_cache(config)
        return cached unless force || due?(config, cached, now)

        refresh(config, now: now)
      end

      def refresh(config, now: Time.now.utc)
        providers = Core::Types::ALL_PROVIDERS.each_with_object({}) do |provider, output|
          output[provider] = fetch_provider(provider, now: now)
        end
        payload = {
          generatedAt: now.iso8601,
          providers: providers
        }
        State.write_status(config, payload)
        payload
      end

      def due?(config, cached, now = Time.now.utc)
        return false unless config.dig(:status, :enabled)
        generated_at = State.parse_time(cached && cached[:generatedAt])
        return true unless generated_at

        generated_at < (now - config.dig(:status, :refreshSeconds).to_i)
      end

      def fetch_provider(provider, now: Time.now.utc)
        metadata = Core::Types::STATUS_METADATA.fetch(provider)
        case provider
        when "gemini"
          fetch_google_status(metadata, now: now)
        when "opencode"
          fetch_usage_endpoint_status(
            metadata,
            now: now,
            key: Providers::Opencode.resolve_api_key,
            key_error: "OpenCode Go API key not found in #{Providers::Opencode.auth_path}.",
            url: Providers::Opencode::USAGE_URL,
            service: "OpenCode Go"
          )
        when "zai"
          fetch_usage_endpoint_status(
            metadata,
            now: now,
            key: Providers::Zai.resolve_api_key,
            key_error: "Z.ai API key not found. Set ZAI_API_KEY or add a zai-coding-plan entry to #{Providers::Zai.auth_path}.",
            url: Providers::Zai::QUOTA_URL,
            service: "Z.ai"
          )
        when "ollama"
          fetch_usage_endpoint_status(
            metadata,
            now: now,
            key: Providers::Ollama.resolve_api_key,
            key_error: "Ollama Cloud API key not found. Set OLLAMA_API_KEY or add an ollama-cloud entry to #{Providers::Ollama.auth_path}.",
            url: Providers::Ollama::BALANCE_URL,
            service: "Ollama Cloud"
          )
        else
          fetch_statuspage(metadata, now: now)
        end.merge(provider: provider)
      rescue StandardError => e
        unknown_status(
          provider,
          source: Core::Types::STATUS_METADATA.dig(provider, :source),
          source_url: Core::Types::STATUS_METADATA.dig(provider, :sourceUrl),
          error: e.message,
          now: now
        )
      end

      def fetch_statuspage(metadata, now:)
        response = Core::Http.request("GET", metadata[:url], headers: { "Accept" => "application/json" })
        raise "Status request failed with HTTP #{response.status}" unless response.status.between?(200, 299)

        payload = Core::Http.parse_json(response)
        matched = matching_components(payload, metadata[:components])
        state = statuspage_state(payload, matched)
        incident = relevant_statuspage_incident(payload, metadata[:components])
        {
          state: state,
          description: statuspage_description(payload, matched, state),
          incident: incident,
          source: metadata[:source],
          sourceUrl: metadata[:sourceUrl],
          updatedAt: now.iso8601,
          components: matched.map { |component| component.slice(:name, :status) }
        }
      end

      def fetch_usage_endpoint_status(metadata, now:, key:, key_error:, url:, service:)
        raise key_error if key.to_s.strip.empty?

        response = Core::Http.request(
          "GET",
          url,
          headers: { "Authorization" => "Bearer #{key}", "Accept" => "application/json" }
        )
        state = response.status.between?(200, 299) ? "ok" : "degraded"
        {
          state: state,
          description: state == "ok" ? "Service operational" : "#{service} usage endpoint returned HTTP #{response.status}",
          incident: nil,
          source: metadata[:source],
          sourceUrl: metadata[:sourceUrl],
          updatedAt: now.iso8601,
          components: []
        }
      end

      def fetch_google_status(metadata, now:)
        response = Core::Http.request("GET", metadata[:url], headers: { "Accept" => "application/json" })
        raise "Status request failed with HTTP #{response.status}" unless response.status.between?(200, 299)

        incidents = Core::Http.parse_json(response)
        active = Array(incidents).select { |incident| google_incident_matches?(incident, metadata[:products]) && google_incident_active?(incident) }
        worst = active.min_by { |incident| google_rank(incident[:status]) }
        state = worst ? GOOGLE_STATES.fetch(worst[:status].to_s, "degraded") : "ok"
        {
          state: state,
          description: worst ? clean_google_text(worst[:external_desc]) : "Service operational",
          incident: worst && clean_google_text(worst[:external_desc]),
          source: metadata[:source],
          sourceUrl: metadata[:sourceUrl],
          updatedAt: now.iso8601,
          components: Array(worst && worst[:affected_products]).filter_map { |product| product[:title] }
        }
      end

      def matching_components(payload, names)
        expected = Array(names).map { |name| name.to_s.downcase }
        Array(payload[:components]).select do |component|
          name = component[:name].to_s.downcase
          expected.any? { |needle| name.include?(needle) }
        end
      end

      def statuspage_state(payload, components)
        states = Array(components).map { |component| STATUSPAGE_COMPONENT_STATES.fetch(component[:status].to_s, "unknown") }
        return "outage" if states.include?("outage")
        return "degraded" if states.include?("degraded")
        return "ok" if states.include?("ok")

        STATUSPAGE_INDICATORS.fetch(payload.dig(:status, :indicator).to_s, "unknown")
      end

      def statuspage_description(payload, components, state)
        degraded = Array(components).reject { |component| component[:status].to_s == "operational" }
        return degraded.map { |component| "#{component[:name]} #{component[:status].to_s.tr('_', ' ')}" }.join(", ") unless degraded.empty?

        payload.dig(:status, :description).to_s.strip.empty? ? (state == "ok" ? "Service operational" : "Status unknown") : payload.dig(:status, :description)
      end

      def relevant_statuspage_incident(payload, names)
        expected = Array(names).map { |name| name.to_s.downcase }
        incident = Array(payload[:incidents]).find do |item|
          unresolved = %w[investigating identified monitoring].include?(item[:status].to_s)
          text = [item[:name], item[:impact], item[:status]].join(" ").downcase
          unresolved && expected.any? { |needle| text.include?(needle) }
        end
        incident && "#{incident[:name]} (#{incident[:status]})"
      end

      def google_incident_matches?(incident, products)
        titles = Array(incident[:affected_products]).map { |product| product[:title].to_s.downcase }
        Array(products).any? do |product|
          needle = product.to_s.downcase
          titles.any? { |title| title.include?(needle) }
        end
      end

      def google_incident_active?(incident)
        return false if incident[:end]

        state = incident[:status].to_s
        !state.empty? && state != "AVAILABLE"
      end

      def google_rank(status)
        case GOOGLE_STATES.fetch(status.to_s, "degraded")
        when "outage" then 0
        when "degraded" then 1
        else 2
        end
      end

      def clean_google_text(value)
        text = value.to_s.gsub(/[#*_`\\]/, "").gsub(/\s+/, " ").strip
        text.empty? ? nil : text
      end

      def unknown_status(provider, source:, source_url:, error:, now:)
        {
          provider: provider,
          state: "unknown",
          description: "Status unavailable",
          incident: nil,
          source: source,
          sourceUrl: source_url,
          updatedAt: now.iso8601,
          error: error
        }
      end
    end
  end
end
