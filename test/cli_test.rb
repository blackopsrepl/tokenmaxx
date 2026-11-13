# frozen_string_literal: true

require_relative "test_helper"

class CliTest < Minitest::Test
  def test_config_dump_and_runtime_cadence_commands
    Dir.mktmpdir("tokenmaxx-cli") do |dir|
      config_path = File.join(dir, "config.json")
      capture_stdout { TokenMaxx::CLI.run(["config", "init", "--config", config_path]) }

      output = capture_stdout do
        assert_equal 0, TokenMaxx::CLI.run(["runtime", "cadence", "manual", "--config", config_path, "--json"])
      end
      runtime = JSON.parse(output)

      assert_equal "manual", runtime["refreshMode"]

      output = capture_stdout do
        assert_equal 0, TokenMaxx::CLI.run(["config", "dump", "--config", config_path, "--json"])
      end
      config = JSON.parse(output)

      assert_equal 5, config["version"]
    end
  end

  def test_cache_clear_all_command
    Dir.mktmpdir("tokenmaxx-cli") do |dir|
      config_path = File.join(dir, "config.json")
      config = build_config
      config[:runtime][:stateDir] = dir
      TokenMaxx::Core::Config.save_config(config, config_path)
      TokenMaxx::Runtime::State.write_status(config, generatedAt: Time.now.utc.iso8601)

      output = capture_stdout do
        assert_equal 0, TokenMaxx::CLI.run(["cache", "clear", "all", "--config", config_path, "--json"])
      end
      payload = JSON.parse(output)

      refute_empty payload["cleared"]
      refute File.exist?(TokenMaxx::Runtime::State.status_path(config))
    end
  end

  def test_provider_visibility_changes_apply_to_disabled_provider
    Dir.mktmpdir("tokenmaxx-cli") do |dir|
      config_path = File.join(dir, "config.json")
      config = build_config
      config[:runtime][:stateDir] = dir
      config = with_provider_state(config, "claude", enabled: false, visible: true)
      TokenMaxx::Core::Config.save_config(config, config_path)

      capture_stdout do
        assert_equal 0, TokenMaxx::CLI.run(["providers", "hide", "claude", "--config", config_path, "--json"])
      end

      updated = TokenMaxx::Core::Config.load_config(config_path)
      claude = TokenMaxx::Core::Config.provider_entry(updated, "claude")
      assert_equal false, claude[:enabled]
      assert_equal false, claude[:visible]
    end
  end

  def test_provider_activation_does_not_block_on_synchronous_refresh
    Dir.mktmpdir("tokenmaxx-cli") do |dir|
      config_path = File.join(dir, "config.json")
      config = build_config
      config[:runtime][:stateDir] = dir
      config = with_provider_state(config, "claude", enabled: false)
      TokenMaxx::Core::Config.save_config(config, config_path)

      TokenMaxx::Runtime::Daemon.stub(:refresh, ->(*) { raise "unexpected refresh" }) do
        capture_stdout do
          assert_equal 0, TokenMaxx::CLI.run(["providers", "activate", "claude", "--config", config_path, "--json"])
        end
      end

      updated = TokenMaxx::Core::Config.load_config(config_path)
      assert_equal true, TokenMaxx::Core::Config.provider_entry(updated, "claude")[:enabled]
    end
  end

  def test_status_refresh_rebuilds_snapshot_for_ui
    Dir.mktmpdir("tokenmaxx-cli") do |dir|
      now = Time.now.utc
      config_path = File.join(dir, "config.json")
      config = build_config
      config[:runtime][:stateDir] = dir
      config = with_provider_state(config, "codex", enabled: true, visible: true, showInOverview: true)
      TokenMaxx::Core::Config.save_config(config, config_path)

      stale_status = {
        generatedAt: now.iso8601,
        providers: {
          "codex" => { provider: "codex", state: "unknown", description: "Status unavailable", updatedAt: now.iso8601 }
        }
      }
      result = provider_result(
        provider: "codex",
        usage: usage_payload(provider: "codex", now: now, primary: window(used_percent: 10, window_minutes: 300, now: now, resets_in_minutes: 60))
      )
      snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[codex], { "codex" => result }, now, service_status: stale_status)
      TokenMaxx::Runtime::State.write_snapshot(config, snapshot)

      fresh_status = {
        generatedAt: now.iso8601,
        providers: {
          "codex" => {
            schemaVersion: 2, provider: "codex", scope: "coding", state: "ok", coverage: "complete",
            freshness: "fresh", description: "Coding services operational", updatedAt: now.iso8601,
            services: [{ id: "api", name: "Codex API", state: "ok", checkedAt: now.iso8601 }],
            incidents: [], incidentCoverage: "complete", sources: []
          }
        }
      }

      TokenMaxx::Runtime::Status.stub(:refresh, ->(loaded_config) {
        TokenMaxx::Runtime::State.write_status(loaded_config, fresh_status)
        fresh_status
      }) do
        TokenMaxx::Runtime::Daemon.stub(:signal_waybar, ->(*) {}) do
          capture_stdout do
            assert_equal 0, TokenMaxx::CLI.run(["status", "--config", config_path, "--json"])
          end
        end
      end

      rebuilt = TokenMaxx::Runtime::State.read_snapshot(config)
      codex = rebuilt.dig(:view, :providers).find { |entry| entry[:id] == "codex" }
      assert TokenMaxx::Runtime::State.result_for(rebuilt, "codex")[:usage]
      assert_equal "ok", codex[:serviceState]
      assert_equal "Operational", codex[:serviceStatusText]
    end
  end

  def test_cost_refresh_rebuilds_snapshot_for_ui
    Dir.mktmpdir("tokenmaxx-cli") do |dir|
      now = Time.now.utc
      config_path = File.join(dir, "config.json")
      config = build_config
      config[:runtime][:stateDir] = dir
      config = with_provider_state(config, "gemini", enabled: true, visible: true, showInOverview: true)
      TokenMaxx::Core::Config.save_config(config, config_path)

      result = provider_result(
        provider: "gemini",
        usage: usage_payload(
          provider: "gemini",
          now: now,
          meters: [
            { key: "model:gemini-3-flash-preview", label: "gemini-3-flash-preview", usedPercent: 10.0, remainingPercent: 90.0 }
          ]
        )
      )
      snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[gemini], { "gemini" => result }, now, local_usage: { providers: {} })
      TokenMaxx::Runtime::State.write_snapshot(config, snapshot)

      fresh_usage = {
        generatedAt: now.iso8601,
        scanDays: 30,
        providers: {
          "gemini" => {
            provider: "gemini",
            supported: true,
            records: 2,
            totalTokens: 1234,
            models: {},
            daily: []
          }
        }
      }

      TokenMaxx::Runtime::LocalUsage.stub(:refresh, ->(loaded_config) {
        TokenMaxx::Runtime::State.write_local_usage(loaded_config, fresh_usage)
        fresh_usage
      }) do
        TokenMaxx::Runtime::Daemon.stub(:signal_waybar, ->(*) {}) do
          capture_stdout do
            assert_equal 0, TokenMaxx::CLI.run(["cost", "--config", config_path, "--json"])
          end
        end
      end

      rebuilt = TokenMaxx::Runtime::State.read_snapshot(config)
      gemini = rebuilt.dig(:view, :providers).find { |entry| entry[:id] == "gemini" }
      assert_equal "1.2k tok · 2 records", gemini[:localUsageText]
    end
  end
end
