# frozen_string_literal: true

module TokenMaxx
  module Runtime
    module Status
      module Claude
        module_function

        def fetch(metadata, previous:, now:)
          source = Status.poll("summary", metadata[:url], previous: previous, now: now) do |payload|
            catalog = Status.validate_components(payload, metadata)
            raise "Missing Claude page identity" unless payload.dig(:page, :id) == metadata[:pageId]
            raise "Invalid Claude incidents" unless payload[:incidents].is_a?(Array)

            incidents = (payload[:incidents] + Array(payload[:scheduled_maintenances])).map do |item|
              raise "Wrong incident page identity" if item[:page_id] && item[:page_id] != metadata[:pageId]
              updates = Array(item[:incident_updates]).sort_by { |u| (Status.parse_time(u[:display_at] || u[:created_at]) || Time.at(0)).to_f }.reverse
              latest = updates.first || {}
              # Only current associations establish current impact. Older update
              # memberships are retained separately for historical scope/context.
              ids = Array(item[:components]).filter_map { |c| c[:id] }
              ids |= Array(latest[:affected_components]).filter_map { |c| c[:code] }
              historical = updates.drop(1).flat_map { |u| Array(u[:affected_components]).filter_map { |c| c[:code] } }.uniq
              impacts = Array(item[:components]).filter_map do |component|
                next unless metadata[:services].any? { |service| service[:id] == component[:id] }

                { id: component[:id], state: Status::STATUSPAGE_COMPONENT_STATES.fetch(component[:status].to_s, "unknown") }
              end
              impacts += Array(latest[:affected_components]).filter_map do |component|
                coding_service = metadata[:services].any? { |service| service[:id] == component[:code] }
                catalog_entry = catalog.find { |entry| entry[:id] == component[:code] }
                next unless coding_service || catalog_entry
                catalog_update = Status.parse_time(catalog_entry && catalog_entry[:updated_at])
                transition_at = Status.parse_time(latest[:display_at] || latest[:created_at])
                next if coding_service && catalog_update && transition_at && catalog_update > transition_at

                { id: component[:code], state: Status::STATUSPAGE_COMPONENT_STATES.fetch(component[:new_status].to_s, "unknown") }
              end
              Status.normalize_incident(item, metadata, catalog: catalog, ids: ids, historical_ids: historical,
                                        current_impacts: impacts, update: latest, now: now)
            end
            services = Status.services_for(catalog, metadata, now: now)
            { services: services, incidents: incidents, coverage: Status.service_coverage(services),
              vendor: { state: Status::STATUSPAGE_INDICATORS.fetch(payload.dig(:status, :indicator).to_s, "unknown"),
                        description: Status.plain_text(payload.dig(:status, :description)), sourceUrl: metadata[:sourceUrl] },
              vendorUpdatedAt: payload.dig(:page, :updated_at) }
          end
          Status.assemble(metadata, health: source, enrichment: source, now: now)
        end
      end
    end
  end
end
