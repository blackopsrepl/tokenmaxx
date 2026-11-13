# frozen_string_literal: true

module TokenMaxx
  module Runtime
    module Status
      module OpenAI
        module_function

        def fetch(metadata, previous:, now:)
          health = Status.poll("components", metadata[:url], previous: previous, now: now) do |payload|
            catalog = Status.validate_components(payload, metadata)
            services = Status.services_for(catalog, metadata, now: now)
            { services: services, catalog: catalog, coverage: Status.service_coverage(services),
              vendorUpdatedAt: catalog.filter_map { |component| component[:updated_at] }.max }
          end
          enrichment = Status.poll("incidents", metadata[:enrichmentUrl], previous: previous, now: now) do |payload|
            parse_native(payload, metadata, now: now)
          end
          extras = []
          if enrichment[:error]
            # Compatibility summaries are context only; absent Codex components
            # and unassociated incidents can never establish coding health.
            fallback = Status.poll("incident-context", metadata[:fallbackUrl], previous: previous, now: now) do |payload|
              catalog = Status.validate_components(payload, metadata)
              raise "Invalid fallback incidents" unless payload[:incidents].is_a?(Array)
              incidents = payload[:incidents].map do |item|
                Status.normalize_incident(item, metadata, catalog: catalog, ids: [],
                                          update: Array(item[:incident_updates]).first || {}, now: now)
              end
              { incidents: incidents, coverage: "partial",
                vendor: { state: Status::STATUSPAGE_INDICATORS.fetch(payload.dig(:status, :indicator).to_s, "unknown"),
                          description: Status.plain_text(payload.dig(:status, :description)), sourceUrl: metadata[:sourceUrl] } }
            end
            extras << fallback
            if !enrichment[:lastSuccessAt] && fallback[:lastSuccessAt]
              # Preserve the failing native source as well as the fallback's own
              # evidence; do not claim complete native incident coverage.
              extras << enrichment
              enrichment = fallback
            end
          end
          result = Status.assemble(metadata, health: health, enrichment: enrichment, extra_sources: extras, now: now)
          result[:incidentCoverage] = "partial" if extras.any? && enrichment[:lastSuccessAt]
          result
        end

        def parse_native(payload, metadata, now:)
          summary = payload.is_a?(Hash) && payload[:summary]
          raise "Invalid OpenAI native response" unless summary.is_a?(Hash) && summary[:id] == metadata[:pageId]
          catalog = Status.validate_components(summary, metadata, page_key: :status_page_id)
          raise "Invalid native incident list" unless summary[:ongoing_incidents].is_a?(Array)
          raise "Invalid native affected components" unless summary[:affected_components].is_a?(Array)
          known_ids = catalog.map { |c| c[:id] }
          summary[:affected_components].each do |component|
            raise "Unknown native component join" unless known_ids.include?(component[:component_id])
          end
          incidents = (summary[:ongoing_incidents] + Array(summary[:scheduled_maintenances])).map do |item|
            raise "Wrong native incident page" unless item[:status_page_id] == metadata[:pageId]
            updates = Array(item[:updates]).sort_by { |u| (Status.parse_time(u[:published_at]) || Time.at(0)).to_f }.reverse
            current = Array(item[:affected_components])
            ids = current.filter_map { |c| c[:component_id] }
            history = Array(item[:component_impacts]).filter_map { |c| c[:component_id] }
            history |= updates.flat_map { |u| Array(u[:component_statuses]).filter_map { |c| c[:component_id] } }
            raise "Unknown native incident component join" unless (ids + history).all? { |id| known_ids.include?(id) }
            impacts = current.map do |c|
              { id: c[:component_id], state: Status::STATUSPAGE_COMPONENT_STATES.fetch((c[:current_status] || c[:status]).to_s, "unknown") }
            end
            latest = updates.first || {}
            latest = latest.merge(message_string: latest[:message_string] || latest.dig(:message, :markdown))
            Status.normalize_incident(item, metadata, catalog: catalog, ids: ids, historical_ids: history,
                                      current_impacts: impacts, update: latest, now: now)
          end
          { incidents: incidents, coverage: "complete", currentImpacts: summary[:affected_components].map do |component|
              { id: component[:component_id], state: Status::STATUSPAGE_COMPONENT_STATES.fetch(component[:status].to_s, "unknown") }
            end }
        end
      end
    end
  end
end
