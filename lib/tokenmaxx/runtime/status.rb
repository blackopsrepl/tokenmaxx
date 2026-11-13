# frozen_string_literal: true

require "time"
require "uri"
require "digest"

module TokenMaxx
  module Runtime
    module Status
      SCHEMA_VERSION = 2
      STATES = %w[ok degraded outage unknown].freeze
      STATUSPAGE_COMPONENT_STATES = {
        "operational" => "ok", "degraded_performance" => "degraded",
        "partial_outage" => "outage", "major_outage" => "outage",
        "under_maintenance" => "unknown"
      }.freeze
      STATUSPAGE_INDICATORS = { "none" => "ok", "minor" => "degraded", "major" => "outage", "critical" => "outage" }.freeze
      GOOGLE_STATES = { "AVAILABLE" => "ok", "SERVICE_INFORMATION" => "unknown", "SERVICE_DISRUPTION" => "degraded", "SERVICE_OUTAGE" => "outage" }.freeze

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
        previous = read_cache(config)
        previous_providers = previous[:providers].is_a?(Hash) ? previous[:providers] : {}
        providers = Core::Types::ALL_PROVIDERS.to_h do |provider|
          [provider, fetch_provider(provider, now: now, previous: previous_providers[provider.to_sym] || previous_providers[provider])]
        end
        payload = { schemaVersion: SCHEMA_VERSION, generatedAt: now.iso8601, providers: providers }
        State.write_status(config, payload)
        payload
      end

      def due?(config, cached, now = Time.now.utc)
        return false unless config.dig(:status, :enabled)
        return true unless cached.is_a?(Hash) && cached[:schemaVersion] == SCHEMA_VERSION && cached[:providers].is_a?(Hash)

        generated_at = parse_time(cached[:generatedAt])
        !generated_at || generated_at < now - config.dig(:status, :refreshSeconds).to_i
      end

      def fetch_provider(provider, now: Time.now.utc, previous: nil)
        metadata = Core::Types::STATUS_METADATA.fetch(provider)
        previous = nil unless previous.is_a?(Hash) && previous[:schemaVersion] == SCHEMA_VERSION
        case provider
        when "codex" then OpenAI.fetch(metadata, previous: previous, now: now)
        when "claude" then Claude.fetch(metadata, previous: previous, now: now)
        when "gemini" then fetch_google_status(metadata, previous: previous, now: now)
        when "opencode" then Opencode.fetch(metadata, previous: previous, now: now)
        else fetch_account_status(provider, metadata, previous: previous, now: now)
        end.merge(provider: provider)
      end

      # Pure consumption-time projection. Never makes a request or mutates the cache.
      def for_display(record, refresh_seconds:, now: Time.now.utc)
        original = record.is_a?(Hash) ? record : {}
        result = Marshal.load(Marshal.dump(original))
        unless scoped_record?(result) && !result[:awaitingScopedRefresh]
          return result.merge(schemaVersion: SCHEMA_VERSION, state: "unknown", scope: "coding", awaitingScopedRefresh: true,
                              description: "Awaiting scoped status refresh", coverage: "unavailable", services: [],
                              incidents: [], incident: nil, incidentCoverage: "unavailable", freshness: "unavailable",
                              updatedAt: nil, staleAt: nil, sources: [])
        end
        ttl = [refresh_seconds.to_i * 2, 120].max
        result[:sources] = Array(result[:sources]).map do |source|
          source.merge(freshness: freshness(source[:lastSuccessAt], ttl, now), staleAt: expiry(source[:lastSuccessAt], ttl))
        end
        result[:services] = Array(result[:services]).map do |service|
          checked = service[:checkedAt] || original[:updatedAt]
          fresh = freshness(checked, ttl, now)
          service = service.merge(freshness: fresh, staleAt: expiry(checked, ttl))
          fresh == "fresh" ? service : service.merge(lastKnownState: service[:lastKnownState] || service[:state], state: "unknown")
        end
        result[:incidents] = Array(result[:incidents]).map do |incident|
          fresh = freshness(incident[:checkedAt], ttl, now)
          value = incident.merge(freshness: fresh, staleAt: expiry(incident[:checkedAt], ttl))
          if fresh == "fresh"
            incident_state(value, result[:services])
          else
            value.merge(lastKnownState: incident[:lastKnownState] || incident[:state], state: "unknown")
          end
        end
        result[:freshness] = freshness(result[:updatedAt], ttl, now)
        result[:staleAt] = expiry(result[:updatedAt], ttl)
        if result[:observation] && result[:services].empty?
          result[:observation][:freshness] = freshness(result[:observation][:checkedAt], ttl, now)
          result[:observation][:staleAt] = expiry(result[:observation][:checkedAt], ttl)
          return result
        end
        health = result[:sources].find { |s| %w[components summary google-products].include?(s[:kind]) }
        if health && health[:freshness] != "fresh"
          result[:coverage] = result[:services].any? { |s| s[:freshness] == "fresh" && s[:state] != "unknown" } ? "partial" : "unavailable"
        end
        incident_source = result[:sources].find { |s| s[:kind] == result[:incidentSourceKind] } || result[:sources].find { |s| %w[incidents summary google-products].include?(s[:kind]) }
        result[:incidentStaleAt] = incident_source && incident_source[:staleAt]
        result[:incidentCoverage] = "unavailable" if incident_source && incident_source[:freshness] != "fresh"
        if result[:freshness] != "fresh" || result[:services].any? { |s| s[:freshness] != "fresh" }
          result[:lastKnownState] = original[:lastKnownState] || original[:state]
          result[:state] = aggregate(result[:services])
          result[:description] = "Coding status has stale service evidence; #{describe(result[:services], result[:state])}"
          known = result[:services].count { |s| s[:state] != "unknown" }
          result[:coverage] = known.positive? ? "partial" : "unavailable"
          result[:description] = "Coding status stale; awaiting fresh evidence" if result[:freshness] == "stale"
          result[:description] = "Coding status unavailable" if result[:freshness] == "unavailable"
        end
        result[:incident] = legacy_incident(result[:incidents])
        result
      end

      def scoped_record?(record)
        record[:schemaVersion] == SCHEMA_VERSION && record[:scope] == "coding" && STATES.include?(record[:state]) &&
          record[:services].is_a?(Array) && record[:services].all? { |s| s.is_a?(Hash) && s[:id].is_a?(String) && STATES.include?(s[:state]) } &&
          record[:incidents].is_a?(Array) && record[:incidents].all? { |i| i.is_a?(Hash) && i[:id].is_a?(String) && STATES.include?(i[:state]) } &&
          Array(record[:sources]).all? { |s| s.is_a?(Hash) }
      end

      def parse_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def expiry(value, ttl)
        time = parse_time(value)
        (time + ttl).iso8601 if time
      end

      def freshness(value, ttl, now)
        time = parse_time(value)
        return "unavailable" unless time

        now < time + ttl ? "fresh" : "stale"
      end

      def request_json(url, headers: {})
        response = Core::Http.request("GET", url, headers: { "Accept" => "application/json" }.merge(headers))
        raise "Status request failed with HTTP #{response.status}" unless response.status.between?(200, 299)

        Core::Http.parse_json(response)
      end

      # Each source retains only its own last successful parsed evidence.
      def poll(kind, url, previous:, now:)
        data = yield request_json(url)
        raise "Invalid normalized source" unless data.is_a?(Hash)

        { kind: kind, url: url, attemptedAt: now.iso8601, lastSuccessAt: now.iso8601,
          vendorUpdatedAt: data[:vendorUpdatedAt], error: nil, coverage: data[:coverage] || "complete", data: data }
      rescue StandardError => e
        old = Array(previous && previous[:sources]).find { |s| s[:kind] == kind && s[:url] == url }
        (old || { kind: kind, url: url, lastSuccessAt: nil, coverage: "unavailable", data: {} }).merge(attemptedAt: now.iso8601, error: plain_text(e.message))
      end

      def validate_components(payload, metadata, page_key: :page_id)
        raise "Invalid component response" unless payload.is_a?(Hash) && payload[:components].is_a?(Array)
        page = payload.dig(:page, :id)
        raise "Wrong status page identity" if page && page != metadata[:pageId]
        payload[:components].each do |component|
          raise "Invalid component identity" unless component.is_a?(Hash) && component[:id].is_a?(String) && component[:name].is_a?(String)
          raise "Wrong component page identity" unless component[page_key] == metadata[:pageId]
        end
        payload[:components]
      end

      def services_for(components, metadata, now:)
        metadata.fetch(:services).map do |expected|
          matches = components.select { |c| c[:id] == expected[:id] }
          valid = matches.size == 1 && expected[:aliases].include?(matches.first[:name])
          raw = valid ? matches.first[:status] : nil
          { id: expected[:id], name: expected[:name], state: STATUSPAGE_COMPONENT_STATES.fetch(raw.to_s, "unknown"),
            rawStatus: raw, scope: "coding", checkedAt: now.iso8601,
            error: valid ? nil : "Required component missing, duplicated, or renamed" }
        end
      end

      def aggregate(services)
        states = Array(services).map { |service| service[:state] }
        return "outage" if states.include?("outage")
        return "degraded" if states.include?("degraded")
        return "ok" if !states.empty? && states.all? { |state| state == "ok" }

        "unknown"
      end

      def service_coverage(services)
        known = services.count { |service| service[:state] != "unknown" }
        return "complete" if !services.empty? && known == services.size

        known.positive? ? "partial" : "unavailable"
      end

      def assemble(metadata, health:, enrichment:, now:, extra_sources: [])
        data = health[:data] || {}
        services = data[:services] || services_for([], metadata, now: now).map { |s| s.merge(checkedAt: nil) }
        incidents = Array(enrichment.dig(:data, :incidents)).map { |i| i.merge(checkedAt: enrichment[:lastSuccessAt]) }
        # Explicit *current* impact can contradict the component feed. Preserve it,
        # visibly, rather than incorrectly returning green from another source.
        services = services.map do |service|
          impacts = incidents.select { |i| %w[investigating identified monitoring].include?(i[:status]) }.flat_map { |i| Array(i[:currentImpacts]) }
          impacts += Array(enrichment.dig(:data, :currentImpacts))
          impacts.select! { |impact| impact[:id] == service[:id] }
          impact = aggregate(impacts)
          if %w[degraded outage].include?(impact) && impact != service[:state] && enrichment[:lastSuccessAt]
            merged_state = aggregate([service, { state: impact }])
            supported_at = merged_state == service[:state] ? service[:checkedAt] : enrichment[:lastSuccessAt]
            service.merge(state: merged_state, conflict: service[:state] != "unknown", checkedAt: supported_at)
          else
            service
          end
        end
        incidents = incidents.map { |i| incident_state(i, services) }
        coverage = service_coverage(services)
        coverage = "partial" if coverage == "complete" && health[:coverage] != "complete"
        state = aggregate(services)
        sources = ([health, enrichment] + extra_sources).uniq.map { |source| source.merge(pageId: metadata[:pageId]) }
        errors = sources.filter_map { |source| source[:error] }
        updated_at = ([health[:lastSuccessAt]] + services.reject { |s| s[:state] == "unknown" }.map { |s| s[:checkedAt] }).compact.max
        {
          schemaVersion: SCHEMA_VERSION, state: state, scope: "coding", description: describe(services, state), coverage: coverage,
          missingServices: services.select { |s| s[:state] == "unknown" || s[:rawStatus].nil? }.map { |s| s[:id] }, services: services,
          incidentSourceKind: enrichment[:kind],
          incidents: sort_incidents(incidents), incident: legacy_incident(incidents), incidentCoverage: enrichment[:error] ? (enrichment[:lastSuccessAt] ? "partial" : "unavailable") : enrichment[:coverage],
          vendor: enrichment.dig(:data, :vendor) || data[:vendor] || { state: "unknown", description: "Vendor-wide status not available", sourceUrl: metadata[:sourceUrl] },
          source: metadata[:source], sourceUrl: metadata[:sourceUrl],
          updatedAt: updated_at, checkedAt: now.iso8601,
          freshness: updated_at ? "fresh" : "unavailable", staleAt: nil, sources: sources,
          error: errors.empty? ? nil : errors.join("; ")
        }
      end

      def describe(services, state)
        return "Coding services vendor-reported operational" if state == "ok"

        services.reject { |s| s[:state] == "ok" }.map { |s| "#{s[:name]}: #{s[:state]}#{s[:conflict] ? ' (conflicting current evidence)' : ''}" }.join("; ")
      end

      def incident_state(incident, services)
        return incident.merge(state: "ok") if %w[resolved completed].include?(incident[:status])
        return incident.merge(state: "unknown") unless (%w[investigating identified monitoring] + GOOGLE_STATES.keys).include?(incident[:status])

        coding = services.select { |s| Array(incident[:currentComponentIds]).include?(s[:id]) }
        state = if coding.empty? && incident[:scope] == "other"
                  aggregate(Array(incident[:currentImpacts]))
                else
                  coding.empty? ? "unknown" : aggregate(coding)
                end
        incident.merge(state: state)
      end

      def sort_incidents(incidents)
        incidents.sort_by do |i|
          [%w[coding mixed unconfirmed other].index(i[:scope]) || 4,
           %w[outage degraded unknown ok].index(i[:state]) || 4,
           %w[critical major minor maintenance none unknown].index(i[:severity]) || 5,
           -(parse_time(i[:updatedAt])&.to_f || 0), i[:id].to_s]
        end
      end

      def legacy_incident(incidents)
        item = sort_incidents(incidents).find { |i| %w[coding mixed].include?(i[:scope]) && %w[outage degraded].include?(i[:state]) && i[:freshness] != "stale" }
        "#{item[:title]} (#{item[:status]})" if item
      end

      def plain_text(value)
        value.to_s.gsub(/<[^>]*>/, "").gsub(/[\x00-\x08\x0b\x0c\x0e-\x1f]/, "").gsub(/\s+/, " ").strip
      end

      def safe_url(value, source_url)
        url = URI.parse(value.to_s)
        source = URI.parse(source_url)
        value if url.scheme == "https" && url.host == source.host && !url.userinfo && (!url.port || url.port == 443)
      rescue URI::InvalidURIError
        nil
      end

      def normalize_incident(item, metadata, catalog:, ids:, historical_ids: [], current_impacts: [], update: {}, now:)
        raise "Invalid incident identity" unless item.is_a?(Hash) && item[:id].is_a?(String) && !item[:id].empty?
        coding_ids = metadata.fetch(:services).map { |s| s[:id] }
        memberships = (ids + historical_ids).uniq
        coding = memberships.any? { |id| coding_ids.include?(id) }
        other = memberships.any? { |id| catalog.any? { |c| c[:id] == id } && !coding_ids.include?(id) }
        unknown = memberships.empty? || memberships.any? { |id| !catalog.any? { |c| c[:id] == id } && !coding_ids.include?(id) }
        scope = coding ? (other ? "mixed" : "coding") : (other && !unknown ? "other" : "unconfirmed")
        current_impacts += ids.filter_map do |id|
          next unless coding_ids.include?(id)
          next if current_impacts.any? { |impact| impact[:id] == id }
          component = catalog.find { |entry| entry[:id] == id }
          next unless component && component[:status]

          { id: id, state: STATUSPAGE_COMPONENT_STATES.fetch(component[:status].to_s, "unknown") }
        end
        { id: item[:id], title: plain_text(item[:name]), url: safe_url(item[:url] || item[:shortlink], metadata[:sourceUrl]) || "#{metadata[:sourceUrl]}incidents/#{URI.encode_www_form_component(item[:id])}",
          status: item[:status].to_s, severity: item[:impact] || "unknown", scope: scope,
          componentIds: memberships, currentComponentIds: ids.uniq, historicalComponentIds: historical_ids.uniq,
          affectedServices: memberships.map { |id| catalog.find { |c| c[:id] == id }&.dig(:name) || coding_ids.include?(id) && metadata[:services].find { |s| s[:id] == id }[:name] || id },
          currentImpacts: current_impacts, updatedAt: update[:display_at] || update[:published_at] || update[:updated_at] || update[:created_at] || item[:updated_at],
          updateText: plain_text(update[:body] || update[:message_string]), checkedAt: now.iso8601, state: "unknown" }
      end

      def fetch_google_status(metadata, previous:, now:)
        source = poll("google-products", metadata[:url], previous: previous, now: now) do |payload|
          raise "Invalid Google incident response" unless payload.is_a?(Array) && payload.all? { |i| i.is_a?(Hash) && i[:affected_products].is_a?(Array) }
          active = payload.map do |item|
            # Google publishes current state on most_recent_update; older
            # compatible fixtures may carry status directly on the incident.
            item.merge(status: item.dig(:most_recent_update, :status) || item[:status] || item[:status_impact])
          end.select { |i| !i[:end] && i[:status] != "AVAILABLE" }
          # The feed lists every incident Google publishes for each product, so a
          # tracked product without an active incident is available, as on
          # status.cloud.google.com itself.
          services = metadata[:products].map do |product|
            matching = active.select { |i| i[:affected_products].any? { |p| p[:title] == product } }
            state = matching.empty? ? "ok" : aggregate(matching.map { |i| { state: GOOGLE_STATES.fetch(i[:status].to_s, "unknown") } })
            { id: product, name: product, state: state, rawStatus: matching.map { |i| i[:status] }.join(","), scope: "coding", sourceScope: "Google Cloud product advisory; not Gemini CLI account or end-to-end inference", checkedAt: now.iso8601 }
          end
          incidents = active.filter_map do |item|
            ids = item[:affected_products].map { |p| p[:title] }.compact
            next if (ids & metadata[:products]).empty? && ids.none? { |title| title.match?(metadata[:otherProductPattern]) }
            id = item[:id] || item[:number] || Digest::SHA256.hexdigest([item[:begin], item[:external_desc], ids.sort].join("|"))
            normalized = normalize_incident(item.merge(id: id.to_s, name: item[:external_desc], status: item[:status], url: item[:uri]),
              metadata.merge(services: metadata[:products].map { |p| { id: p, name: p } }), catalog: ids.map { |p| { id: p, name: p } }, ids: ids,
              update: { body: item.dig(:most_recent_update, :text), updated_at: item[:modified] }, now: now)
            normalized = normalized.merge(currentImpacts: ids.reject { |title| metadata[:products].include?(title) }
                                                              .map { |title| { id: title, state: GOOGLE_STATES.fetch(item[:status].to_s, "unknown") } }) if normalized[:scope] == "other"
            normalized.merge(sourceScope: "Google Cloud product advisory")
          end
          { services: services, incidents: incidents, coverage: "complete" }
        end
        assemble(metadata.merge(services: metadata[:products].map { |p| { id: p, name: p, aliases: [p] } }), health: source, enrichment: source, now: now)
      end

      def valid_account_payload?(provider, payload)
        return false unless payload.is_a?(Hash)

        case provider
        when "zai"
          payload[:data].is_a?(Hash) && Array(payload[:data][:limits]).any? do |limit|
            limit.is_a?(Hash) && Providers::Zai::QUOTA_WINDOW_TYPES.include?(limit[:type]) &&
              [Providers::Zai::UNIT_SESSION, Providers::Zai::UNIT_WEEKLY].include?(limit[:unit]) && limit[:percentage].is_a?(Numeric)
          end
        when "ollama"
          included = payload[:included]
          included.is_a?(Hash) && ((included[:balance_usd].is_a?(Numeric) && included[:allowance_usd].is_a?(Numeric)) ||
            %i[session weekly].any? { |key| included[key].is_a?(Hash) && included[key][:remaining_percent].is_a?(Numeric) })
        else false
        end
      end

      def fetch_account_status(provider, metadata, previous:, now:)
        implementation = { "zai" => Providers::Zai, "ollama" => Providers::Ollama }.fetch(provider)
        url = provider == "zai" ? implementation::QUOTA_URL : implementation::BALANCE_URL
        observation = { state: "unknown", description: "Account check unavailable", checkedAt: now.iso8601, error: nil }
        begin
          key = implementation.resolve_api_key
          raise "authentication/access: account API key not available" if key.to_s.strip.empty?
          response = Core::Http.request("GET", url, headers: { "Authorization" => "Bearer #{key}", "Accept" => "application/json" })
          unless response.status.between?(200, 299)
            category = case response.status
                       when 401, 403 then "authentication/access"
                       when 429 then "account/rate limit"
                       when 500..599 then "account endpoint"
                       else "account request"
                       end
            raise "#{category} error: HTTP #{response.status}"
          end
          payload = Core::Http.parse_json(response)
          raise "Malformed account response" unless valid_account_payload?(provider, payload)
          observation.merge!(state: "ok", description: "Account endpoint reachable (not inference health)")
        rescue StandardError => e
          category = if e.is_a?(Timeout::Error)
                       "timeout/network: "
                     elsif e.is_a?(SocketError) || e.is_a?(SystemCallError) || e.is_a?(IOError)
                       "network: "
                     else
                       ""
                     end
          observation.merge!(state: "error", description: "Account check failed (not inference health)", error: plain_text("#{category}#{e.message}"))
        end
        success = observation[:state] == "ok" ? now.iso8601 : previous&.dig(:sources)&.first&.dig(:lastSuccessAt)
        if observation[:state] != "ok" && previous && previous[:observation]
          old = previous[:observation]
          observation[:lastGood] = old[:state] == "ok" ? old.reject { |key, _| key == :lastGood } : old[:lastGood]
        end
        # Z.ai and Ollama publish no status page, so there is no coding health to
        # report; the account check is an observation, never service health.
        { schemaVersion: SCHEMA_VERSION, state: "unknown", scope: "coding", statusPage: false, description: "No public status page; account check only",
          coverage: "unavailable", services: [], incidents: [], incident: nil, incidentCoverage: "unavailable",
          vendor: { state: "unknown", description: "No authoritative public coding health source", sourceUrl: metadata[:sourceUrl] },
          observation: observation, source: metadata[:source], sourceUrl: metadata[:sourceUrl], updatedAt: nil, checkedAt: now.iso8601,
          freshness: "unavailable", staleAt: nil,
          sources: [{ kind: "account", url: url, attemptedAt: now.iso8601, lastSuccessAt: success, vendorUpdatedAt: nil, error: observation[:error], coverage: "unavailable" }] }
      end
    end
  end
end

require_relative "status/claude"
require_relative "status/openai"
require_relative "status/opencode"
