# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module TokenMaxx
  module Runtime
    module State
      SNAPSHOT_VERSION = 4
      SNAPSHOT_FILE = "snapshot.json"
      UI_STATE_FILE = "ui.json"
      STATUS_FILE = "status.json"
      HISTORY_FILE = "history.json"
      LOCAL_USAGE_FILE = "local_usage.json"
      STORAGE_FILE = "storage.json"
      NOTIFICATION_STATE_FILE = "notification_state.json"
      DAEMON_LOCK_FILE = "daemon.lock"
      REFRESH_LOCK_FILE = "refresh.lock"
      LEGACY_IMPORT_MARKER = ".codexbar-state-imported"

      module_function

      def state_dir(config)
        File.expand_path(config.dig(:runtime, :stateDir))
      end

      def snapshot_path(config)
        File.join(state_dir(config), SNAPSHOT_FILE)
      end

      def ui_state_path(config)
        File.join(state_dir(config), UI_STATE_FILE)
      end

      def status_path(config)
        File.join(state_dir(config), STATUS_FILE)
      end

      def history_path(config)
        File.join(state_dir(config), HISTORY_FILE)
      end

      def local_usage_path(config)
        File.join(state_dir(config), LOCAL_USAGE_FILE)
      end

      def storage_path(config)
        File.join(state_dir(config), STORAGE_FILE)
      end

      def notification_state_path(config)
        File.join(state_dir(config), NOTIFICATION_STATE_FILE)
      end

      def read_snapshot(config)
        path = snapshot_path(config)
        return nil unless File.file?(path)

        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def write_snapshot(config, snapshot)
        ensure_state_dir(config)
        atomic_write_json(snapshot_path(config), snapshot)
      end

      def build_snapshot(config, enabled, results, now = Time.now.utc, service_status: nil, local_usage: nil, storage: nil, history: nil)
        visible = Usage.visible_providers(config, enabled)
        snapshot = {
          snapshotVersion: SNAPSHOT_VERSION,
          generatedAt: now.iso8601,
          enabledProviders: enabled,
          visibleProviders: visible,
          hiddenProviders: Usage.hidden_providers(config, enabled),
          overviewProviders: overview_providers(config, enabled),
          autoSelectableProviders: Usage.auto_selectable_providers(config, enabled),
          selectedProvider: Usage.selected_provider(config, enabled),
          displayProvider: Usage.display_provider(config, enabled, results),
          serviceStatus: status_payload(config, payload: service_status || read_status(config), now: now),
          localUsage: local_usage || read_local_usage(config),
          storage: storage || read_storage(config),
          history: history || read_history(config),
          results: results
        }
        snapshot[:view] = Presenter.build_snapshot_view(config, snapshot, now)
        snapshot
      end

      def rebuild_snapshot(config, previous: nil)
        previous ||= read_snapshot(config)
        enabled = Usage.enabled_providers(config)
        cached = snapshot_results(previous)
        results = enabled.each_with_object({}) do |provider, output|
          result = cached[provider] || cached[provider.to_sym]
          output[provider] = result if result
        end
        snapshot = build_snapshot(
          config,
          enabled,
          results,
          Time.now.utc,
          service_status: read_status(config),
          local_usage: read_local_usage(config),
          storage: read_storage(config),
          history: read_history(config)
        )
        snapshot[:generatedAt] = previous[:generatedAt] if previous && previous[:generatedAt]
        snapshot[:view] = Presenter.build_snapshot_view(config, snapshot, Time.now)
        write_snapshot(config, snapshot)
        snapshot
      end

      def generated_time(snapshot)
        parse_time(snapshot && (snapshot[:generatedAt] || snapshot["generatedAt"]))
      end

      def stale?(snapshot, config, now = Time.now)
        generated = generated_time(snapshot)
        return true unless generated

        generated < (now - stale_after_seconds(config))
      end

      def stale_after_seconds(config)
        [config.dig(:runtime, :refreshSeconds).to_i * 2, 60].max
      end

      def result_for(snapshot, provider)
        results = snapshot_results(snapshot)
        results[provider] || results[provider.to_sym]
      end

      def snapshot_results(snapshot)
        snapshot&.dig(:results) || snapshot&.dig("results") || {}
      end

      def read_status(config)
        payload = read_json_file(status_path(config))
        payload.is_a?(Hash) ? payload : {}
      end

      def status_payload(config, payload: nil, now: Time.now.utc)
        payload ||= read_status(config)
        payload = {} unless payload.is_a?(Hash)
        providers = payload[:providers].is_a?(Hash) ? payload[:providers] : {}
        payload.merge(providers: providers.to_h do |provider, record|
          [provider, Status.for_display(record, refresh_seconds: config.dig(:status, :refreshSeconds), now: now)]
        end)
      end

      def snapshot_for_display(config, snapshot, now = Time.now.utc)
        return {} unless snapshot

        projected = snapshot.merge(serviceStatus: status_payload(config, payload: snapshot[:serviceStatus] || {}, now: now))
        projected.merge(view: Presenter.build_snapshot_view(config, projected, now))
      end

      def write_status(config, payload)
        write_json_file(status_path(config), payload)
      end

      def read_history(config)
        read_json_file(history_path(config)) || {}
      end

      def write_history(config, payload)
        write_json_file(history_path(config), payload)
      end

      def read_local_usage(config)
        read_json_file(local_usage_path(config)) || {}
      end

      def write_local_usage(config, payload)
        write_json_file(local_usage_path(config), payload)
      end

      def read_storage(config)
        read_json_file(storage_path(config)) || {}
      end

      def write_storage(config, payload)
        write_json_file(storage_path(config), payload)
      end

      def read_notification_state(config)
        read_json_file(notification_state_path(config)) || {}
      end

      def write_notification_state(config, payload)
        write_json_file(notification_state_path(config), payload)
      end

      def delete_cache(config, name)
        path = case name.to_s
               when "snapshot" then snapshot_path(config)
               when "status" then status_path(config)
               when "history" then history_path(config)
               when "cost", "local_usage", "local-usage" then local_usage_path(config)
               when "storage" then storage_path(config)
               when "notifications", "notification_state", "notification-state" then notification_state_path(config)
               else
                 raise ArgumentError, "Unknown cache target #{name}."
               end
        FileUtils.rm_f(path)
        path
      end

      def delete_all_caches(config)
        %w[snapshot status history cost storage notifications].map { |name| delete_cache(config, name) }
      end

      def enabled_providers(snapshot)
        Array(snapshot&.dig(:enabledProviders) || snapshot&.dig("enabledProviders")).map(&:to_s)
      end

      def visible_providers(snapshot)
        Array(snapshot&.dig(:visibleProviders) || snapshot&.dig("visibleProviders")).map(&:to_s)
      end

      def hidden_providers(snapshot)
        Array(snapshot&.dig(:hiddenProviders) || snapshot&.dig("hiddenProviders")).map(&:to_s)
      end

      def read_ui_state(config)
        path = ui_state_path(config)
        return default_ui_state unless File.file?(path)

        normalize_ui_state(JSON.parse(File.read(path), symbolize_names: true))
      rescue JSON::ParserError
        default_ui_state
      end

      def write_ui_state(config, ui_state)
        ensure_state_dir(config)
        atomic_write_json(ui_state_path(config), normalize_ui_state(ui_state))
      end

      def default_ui_state
        {
          open: false,
          focusProvider: "",
          requestedAt: ""
        }
      end

      def normalize_ui_state(ui_state)
        state = default_ui_state.merge((ui_state || {}).transform_keys(&:to_sym))
        state[:open] = !!state[:open]
        state[:focusProvider] = state[:focusProvider].to_s
        state[:requestedAt] = state[:requestedAt].to_s
        state
      end

      def overview_providers(config, enabled)
        Usage.overview_providers(config, enabled)
      end

      def provider_updated_at(result, snapshot)
        timestamp = result&.dig(:usage, :updatedAt) ||
          result&.dig(:credits, :updatedAt) ||
          result&.dig(:providerCost, :updatedAt) ||
          result&.dig(:spend, :month, :updatedAt) ||
          snapshot&.dig(:generatedAt)
        parse_time(timestamp)
      end

      def with_refresh_lock(config)
        ensure_state_dir(config)
        File.open(lock_path(config, REFRESH_LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          yield
        end
      end

      def acquire_daemon_lock(config)
        ensure_state_dir(config)
        file = File.open(lock_path(config, DAEMON_LOCK_FILE), File::RDWR | File::CREAT, 0o600)
        return nil unless file.flock(File::LOCK_EX | File::LOCK_NB)

        file.rewind
        file.write("#{::Process.pid}\n")
        file.flush
        file
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN
        nil
      end

      def ensure_state_dir(config)
        dir = state_dir(config)
        marker = File.join(dir, LEGACY_IMPORT_MARKER)
        if !File.exist?(marker) && dir != legacy_state_dir
          import_legacy_state_files!(dir)
        end
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        File.write(marker, "#{::Process.pid}\n") unless File.exist?(marker)
        dir
      end

      # One-time import of pre-rebrand state (history, local usage, ui and
      # notification state). Guarded by a marker file, not directory
      # existence: a pre-created empty state dir still migrates, and a later
      # cache clear can never resurrect old files. *.json only, so legacy
      # daemon/refresh locks never migrate. Old files are left in place,
      # never deleted.
      def import_legacy_state_files!(dir)
        legacy_files = Dir.glob(File.join(legacy_state_dir, "*.json"))
        return if legacy_files.empty?

        FileUtils.mkdir_p(dir)
        legacy_files.each do |source|
          target = File.join(dir, File.basename(source))
          next if File.exist?(target)

          temp = "#{target}.import.#{::Process.pid}"
          FileUtils.cp(source, temp)
          FileUtils.chmod(0o600, temp)
          File.rename(temp, target)
        end
      end

      def legacy_state_dir
        File.expand_path(File.join(Dir.home, ".local", "state", "codexbar"))
      end

      def ensure_ui_state(config)
        ensure_state_dir(config)
        write_ui_state(config, default_ui_state) unless File.file?(ui_state_path(config))
      end

      def atomic_write_json(path, payload)
        temp_path = "#{path}.tmp.#{$$}"
        File.write(temp_path, "#{JSON.pretty_generate(payload)}\n")
        File.chmod(0o600, temp_path)
        File.rename(temp_path, path)
        File.chmod(0o600, path)
        path
      ensure
        FileUtils.rm_f(temp_path) if temp_path && File.exist?(temp_path)
      end

      def lock_path(config, name)
        File.join(state_dir(config), name)
      end

      def read_json_file(path)
        return nil unless File.file?(path)

        JSON.parse(File.read(path), symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      def write_json_file(path, payload)
        ensure_state_dir_for(path)
        atomic_write_json(path, payload)
      end

      def ensure_state_dir_for(path)
        FileUtils.mkdir_p(File.dirname(path))
      end

      def parse_time(value)
        return nil if value.to_s.strip.empty?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
