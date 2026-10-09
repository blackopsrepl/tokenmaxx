# frozen_string_literal: true

module TokenMaxx
  module Runtime
    module Daemon
      module_function

      def run(config_path, once: false)
        config = Core::Config.load_config(config_path)
        return refresh(config_path, config: config) if once

        lock = State.acquire_daemon_lock(config)
        raise "tokenmaxx daemon already running for #{State.state_dir(config)}." unless lock

        refresh(config_path, config: config)

        loop do
          config = Core::Config.load_config(config_path)
          sleep(config.dig(:runtime, :refreshMode) == "manual" ? 5 : config.dig(:runtime, :refreshSeconds).to_i)
          next if config.dig(:runtime, :refreshMode) == "manual"

          refresh(config_path, config: config)
        rescue StandardError => e
          warn "tokenmaxx daemon refresh error: #{e.message}"
        end
      ensure
        lock&.close
      end

      def refresh(config_path, config: nil)
        config ||= Core::Config.load_config(config_path)
        snapshot = nil

        State.with_refresh_lock(config) do
          # The config object may predate this refresh (the daemon loop hands
          # down the config it loaded before sleeping), so re-read it before
          # deciding which providers to fetch.
          config = Core::Config.load_config(config_path)
          enabled = Usage.enabled_providers(config)
          results = Usage.collect_usage(config, enabled)
          previous = State.read_snapshot(config)
          results = retain_cached_usage(results, previous)
          service_status = Status.refresh_if_due(config)
          local_usage = LocalUsage.refresh_if_due(config)
          storage = Storage.refresh_if_due(config)
          draft = State.build_snapshot(
            config,
            enabled,
            results,
            service_status: service_status,
            local_usage: local_usage,
            storage: storage
          )
          history = History.update(config, draft, local_usage)
          # The auxiliary refreshes above can take seconds when due. Re-read
          # once more at the last moment so a pin/swap landing in that window
          # survives this write instead of reverting the bar.
          config = Core::Config.load_config(config_path)
          enabled = Usage.enabled_providers(config)
          # The enabled set may have changed while the fetches and auxiliary
          # refreshes were in flight; drop results for providers disabled
          # since, so the snapshot stays consistent with the fresh config.
          # Providers enabled mid-refresh simply have no result yet and fill
          # in on the next pass.
          results = results.select { |provider, _| enabled.include?(provider.to_s) }
          snapshot = State.build_snapshot(
            config,
            enabled,
            results,
            service_status: service_status,
            local_usage: local_usage,
            storage: storage,
            history: history
          )
          Notifications.process(config, previous, snapshot)
          State.write_snapshot(config, snapshot)
        end

        signal_waybar(config)
        snapshot
      end

      def retain_cached_usage(results, previous)
        cached = State.snapshot_results(previous)
        results.each_with_object({}) do |(provider, result), retained|
          prior = cached[provider] || cached[provider.to_sym]
          if result && result[:error] && !result[:usage] && prior && prior[:usage]
            retained[provider] = prior.merge(result).merge(
              usage: prior[:usage],
              credits: prior[:credits],
              notes: (Array(prior[:notes]) + Array(result[:notes]) + ["Showing last cached quota after refresh failure."]).uniq
            ).compact
          else
            retained[provider] = result
          end
        end
      end

      def signal_waybar(config)
        signal = config.dig(:runtime, :waybarSignal).to_i
        return if signal <= 0

        Core::Process.run_command("pkill", ["-RTMIN+#{signal}", "waybar"])
      rescue StandardError
        nil
      end
    end
  end
end
