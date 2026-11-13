# frozen_string_literal: true

require "time"

module TokenMaxx
  module Runtime
    module Notifications
      module_function

      def process(config, previous_snapshot, snapshot, now: Time.now.utc)
        return State.read_notification_state(config) unless config.dig(:notifications, :enabled)

        state = normalize_state(State.read_notification_state(config))
        provider_states = state[:providers]

        Core::Types::ALL_PROVIDERS.each do |provider|
          provider_states[provider] ||= {}
          next unless Core::Types.provider_config_for(config, provider)[:enabled]

          current = current_provider_state(config, snapshot, provider, now: now)
          previous = provider_states[provider]
          notify_quota_transition(config, provider, previous[:quotaLevel], current[:quotaLevel]) if config.dig(:notifications, :quotaWarnings)
          outstanding = (previous[:notifiedImpacts] || {}).transform_keys(&:to_s)
          if config.dig(:notifications, :incidentWarnings)
            outstanding = notify_service_impacts(config, provider, outstanding, current[:service])
          end
          provider_states[provider] = current.reject { |key, _| key == :service }.merge(notifiedImpacts: outstanding, updatedAt: now.iso8601)
        end

        output = {
          generatedAt: now.iso8601,
          providers: provider_states
        }
        State.write_notification_state(config, output)
        output
      end

      def normalize_state(input)
        {
          generatedAt: input && input[:generatedAt],
          providers: (input && input[:providers] || {}).each_with_object({}) do |(provider, state), output|
            output[provider.to_s] = (state || {}).transform_keys(&:to_sym)
          end
        }
      end

      def current_provider_state(config, snapshot, provider, now: Time.now.utc)
        result = State.result_for(snapshot, provider)
        usage = result && result[:usage]
        windows = usage ? Core::Metric.metric_windows(usage) : []
        service = Status.for_display(provider_service_status(snapshot, provider), refresh_seconds: config.dig(:status, :refreshSeconds), now: now)
        {
          quotaLevel: Core::Metric.worst_quota_level(
            windows,
            warning_threshold: config.dig(:notifications, :warningThreshold),
            critical_threshold: config.dig(:notifications, :criticalThreshold)
          ) || "unknown",
          serviceState: service[:state].to_s.empty? ? "unknown" : service[:state].to_s,
          serviceText: Core::Format.service_status_text(service),
          service: service
        }
      end

      def provider_service_status(snapshot, provider)
        snapshot&.dig(:serviceStatus, :providers, provider) ||
          snapshot&.dig(:serviceStatus, :providers, provider.to_sym) ||
          {}
      end

      def notify_quota_transition(config, provider, previous, current)
        return if previous == current
        return unless %w[warning critical ok].include?(current)
        return if previous.nil? && current == "ok"

        label = Core::Types::PROVIDER_METADATA.fetch(provider)[:label]
        case current
        when "critical"
          notify(config, "TokenMaxx", "#{label} quota is critical.")
        when "warning"
          notify(config, "TokenMaxx", "#{label} quota is low.")
        when "ok"
          notify(config, "TokenMaxx", "#{label} quota recovered.")
        end
      end

      def notify_service_impacts(config, provider, outstanding, service)
        return outstanding unless service[:freshness] == "fresh"

        active = confirmed_impacts(service)
        active.keys.each do |key|
          impact = active[key]
          if key.start_with?("component:")
            owner = outstanding.find { |prior_key, prior| prior_key.start_with?("incident:") && (Array(prior[:componentIds]) & impact[:componentIds]).any? }
            if owner
              active.delete(key)
              existing = active[owner.first]
              severity = [existing && existing[:state], impact[:state]].compact.max_by { |state| impact_rank(state) }
              active[owner.first] = owner.last.merge(state: severity)
            end
          else
            component_keys = impact[:componentIds].map { |id| "component:#{id}" }
            prior = component_keys.filter_map { |component_key| outstanding[component_key] }.max_by { |entry| impact_rank(entry[:state]) }
            if prior
              outstanding = outstanding.reject { |prior_key, _| component_keys.include?(prior_key) }
              outstanding[key] = impact.merge(state: prior[:state])
            end
          end
        end
        changed = active.select do |key, impact|
          prior = outstanding[key]
          prior.nil? || impact_rank(impact[:state]) > impact_rank(prior[:state]) ||
            (Array(impact[:componentIds]) - Array(prior[:componentIds])).any?
        end
        label = Core::Types::PROVIDER_METADATA.fetch(provider)[:label]
        unless changed.empty?
          titles = changed.values.map { |impact| impact[:title] }.uniq.join("; ")
          if notify(config, "TokenMaxx", "#{label} coding services affected: #{titles}")
            outstanding = outstanding.merge(changed)
          end
        end

        remaining = outstanding.reject do |key, impact|
          !active.key?(key) && impact_recovered?(impact, service)
        end
        if !outstanding.empty? && remaining.empty?
          return outstanding unless service[:state] == "ok" && service[:coverage] == "complete"
          return outstanding unless notify(config, "TokenMaxx", "#{label} coding services recovered.")
        end
        remaining.each_with_object({}) do |(key, impact), output|
          output[key] = active[key] || impact
        end
      end

      def confirmed_impacts(service)
        return {} unless service[:scope] == "coding" && %w[degraded outage].include?(service[:state])

        components = Array(service[:services]).select { |entry| %w[degraded outage].include?(entry[:state]) }
        output = {}
        covered = []
        Array(service[:incidents]).each do |incident|
          next unless %w[coding mixed].include?(incident[:scope])
          next unless %w[degraded outage].include?(incident[:state])

          coding_ids = Array(service[:services]).map { |entry| entry[:id].to_s }
          ids = Array(incident[:currentComponentIds] || incident[:componentIds]).map(&:to_s) & coding_ids
          next if incident[:id].to_s.empty? || ids.empty?

          affected_names = Array(service[:services]).select { |entry| ids.include?(entry[:id].to_s) }.map { |entry| entry[:name] || entry[:id] }
          output["incident:#{incident[:id]}"] = {
            state: incident[:state], title: "#{incident[:title]} (#{affected_names.join(', ')})", componentIds: ids
          }
          covered.concat(ids)
        end
        components.each do |component|
          id = component[:id].to_s
          next if id.empty? || covered.include?(id)

          output["component:#{id}"] = { state: component[:state], title: "#{component[:name]} #{component[:state]}", componentIds: [id] }
        end
        output
      end

      def impact_recovered?(impact, service)
        ids = Array(impact[:componentIds]).map(&:to_s)
        return service[:state] == "ok" && service[:coverage] == "complete" if ids.empty?

        components = Array(service[:services]).to_h { |entry| [entry[:id].to_s, entry] }
        ids.all? { |id| components[id] && components[id][:state] == "ok" }
      end

      def impact_rank(state)
        { "degraded" => 1, "outage" => 2 }.fetch(state.to_s, 0)
      end

      def notify(config, title, message)
        command = config.dig(:runtime, :notificationCommand).to_s.strip
        return if command.empty?

        Core::Process.spawn_detached(command, [title, message])
      rescue StandardError
        nil
      end
    end
  end
end
