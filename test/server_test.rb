# frozen_string_literal: true

require_relative "test_helper"

class ServerTest < Minitest::Test
  def test_cached_routes_expire_service_evidence_without_network_or_cache_writes
    Dir.mktmpdir("tokenmaxx-server") do |dir|
      now = Time.now.utc
      config = with_provider_state(build_config, "codex", enabled: true, visible: true)
      config[:runtime][:stateDir] = dir
      record = {
        schemaVersion: 2, provider: "codex", scope: "coding", state: "outage", coverage: "complete",
        description: "Coding services outage", updatedAt: (now - 1200).iso8601,
        staleAt: (now - 600).iso8601, freshness: "fresh",
        services: [{ id: "api", name: "Codex API", state: "outage" }], incidents: []
      }
      status = { schemaVersion: 2, generatedAt: now.iso8601, providers: { "codex" => record } }
      TokenMaxx::Runtime::State.write_status(config, status)
      snapshot = TokenMaxx::Runtime::State.build_snapshot(config, ["codex"], {}, now, service_status: status)
      TokenMaxx::Runtime::State.write_snapshot(config, snapshot)
      before = File.binread(TokenMaxx::Runtime::State.status_path(config))
      TokenMaxx::Core::Http.stub(:request, ->(*) { flunk "cached routes must not fetch" }) do
        projected = TokenMaxx::Runtime::Server.payload(config, "/status")
        assert_equal "unknown", projected.dig(:providers, :codex, :state)
        assert_equal "stale", projected.dig(:providers, :codex, :freshness)
        usage = TokenMaxx::Runtime::Server.payload(config, "/usage")
        assert_equal "unknown", usage.dig(:serviceStatus, :providers, :codex, :state)
        assert_equal snapshot[:generatedAt], usage[:generatedAt]
      end
      assert_equal before, File.binread(TokenMaxx::Runtime::State.status_path(config))
    end
  end

  def test_malformed_cache_shape_is_unavailable_not_a_cached_read_crash
    Dir.mktmpdir("tokenmaxx-server") do |dir|
      config = build_config
      config[:runtime][:stateDir] = dir
      [[], { schemaVersion: 2, generatedAt: Time.now.utc.iso8601, providers: [] }].each do |malformed|
        TokenMaxx::Runtime::State.write_status(config, malformed)
        assert_empty TokenMaxx::Runtime::Server.payload(config, "/status")[:providers]
        assert TokenMaxx::Runtime::Status.due?(config, TokenMaxx::Runtime::State.read_status(config))
      end
    end
  end

  def test_health_payload_reports_missing_snapshot
    Dir.mktmpdir("tokenmaxx-state") do |dir|
      config = build_config
      config[:runtime][:stateDir] = dir

      payload = TokenMaxx::Runtime::Server.payload(config, "/health")

      assert_equal true, payload[:ok]
      assert_equal false, payload[:snapshotPresent]
    end
  end
end
