# frozen_string_literal: true

module TokenMaxx
  module Runtime
    module Status
      # OpenCode's documented public status JSON (`GET /api/status`, no auth). The
      # Inference API gateway and the Go plan are the coding services for OpenCode
      # Go; Console, Request logs, Pay-as-you-go and Free inference are other
      # services, so their incidents never read as a Go outage.
      module Opencode
        STATES = { "operational" => "ok", "degraded" => "degraded", "outage" => "outage" }.freeze

        module_function

        def fetch(metadata, previous:, now:)
          source = Status.poll("status", metadata[:url], previous: previous, now: now) do |payload|
            raise "Invalid OpenCode status response" unless payload.is_a?(Hash) && payload[:components].is_a?(Array) && payload[:incidents].is_a?(Array)
            raise "OpenCode status reports stale data" if payload[:stale]

            catalog = payload[:components].map do |component|
              raise "Invalid OpenCode component" unless component.is_a?(Hash) && component[:service].is_a?(String)

              id = component[:service]
              { id: id, name: metadata[:componentNames].fetch(id, id), status: component[:status].to_s }
            end
            services = metadata[:services].map do |expected|
              matches = catalog.select { |component| component[:id] == expected[:id] }
              raw = matches.size == 1 ? matches.first[:status] : nil
              { id: expected[:id], name: expected[:name], state: STATES.fetch(raw.to_s, "unknown"), rawStatus: raw,
                scope: "coding", checkedAt: now.iso8601,
                error: raw ? nil : "Required component missing or duplicated" }
            end
            incidents = payload[:incidents].select { |item| item.is_a?(Hash) && item[:resolvedAt].nil? }.map do |item|
              service = item[:service].to_s
              state = STATES.fetch(item[:status].to_s, "unknown")
              started = item[:startedAt].is_a?(Numeric) ? Time.at(item[:startedAt] / 1000.0).utc.iso8601 : nil
              reason = { "latency" => "Slow responses", "upstream" => "Upstream provider issues" }.fetch(item[:reason].to_s, "Elevated error rates")
              title = "#{reason} · #{metadata[:componentNames].fetch(service, service)}"
              Status.normalize_incident({ id: item[:id].to_s, name: title, status: "investigating", impact: state == "outage" ? "major" : "minor",
                                          url: metadata[:sourceUrl], updated_at: started },
                                        metadata, catalog: catalog, ids: [service], current_impacts: [{ id: service, state: state }], now: now)
            end
            vendor_at = payload[:updatedAt].is_a?(Numeric) ? Time.at(payload[:updatedAt] / 1000.0).utc.iso8601 : nil
            { services: services, incidents: incidents, coverage: Status.service_coverage(services),
              vendor: { state: STATES.fetch(payload[:status].to_s, "unknown"), description: "OpenCode #{payload[:status]}", sourceUrl: metadata[:sourceUrl] },
              vendorUpdatedAt: vendor_at }
          end
          Status.assemble(metadata, health: source, enrichment: source, now: now)
        end
      end
    end
  end
end
