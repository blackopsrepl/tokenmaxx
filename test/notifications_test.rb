# frozen_string_literal: true

require_relative "test_helper"

class NotificationsTest < Minitest::Test
  def scoped_service(state: "degraded", id: "incident-a", component: "api", freshness: "fresh")
    {
      schemaVersion: 2, scope: "coding", state: state, freshness: freshness, coverage: "complete",
      updatedAt: Time.now.utc.iso8601, staleAt: (Time.now.utc + 600).iso8601,
      services: [{ id: component, name: "Codex API", state: state }],
      incidents: [{ id: id, title: "Elevated coding errors", scope: "coding", state: state, componentIds: [component] }]
    }
  end

  def test_coding_incident_identity_escalation_and_recovery_are_not_poll_events
    config = build_config
    messages = []
    service = scoped_service
    outstanding = {}
    TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, service)
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, service)
      service[:incidents].first[:title] = "Edited vendor wording"
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, service)
      assert_equal 1, messages.length
      service[:incidents] << service[:incidents].first.merge(id: "incident-b")
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, service)
      assert_equal 2, messages.length
      service[:state] = "outage"
      service[:services].first[:state] = "outage"
      service[:incidents].each { |incident| incident[:state] = "outage" }
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, service)
      assert_equal 3, messages.length
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, scoped_service(state: "ok"))
      assert_empty outstanding
      TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, scoped_service(state: "ok"))
      assert_equal 4, messages.length
      assert_includes messages.last, "recovered"
    end
  end

  def test_other_incidents_and_unknown_coverage_never_notify_or_recover
    config = build_config
    messages = []
    service = scoped_service
    TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", {}, service)
      unknown = service.merge(state: "unknown", coverage: "unavailable", services: [], incidents: [])
      retained = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, unknown)
      assert_equal outstanding, retained
      stale = scoped_service(state: "ok", freshness: "stale")
      assert_equal outstanding, TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, stale)
      other = scoped_service(state: "ok")
      other[:incidents] = [{ id: "connector", scope: "other", state: "outage" }]
      assert_empty TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", {}, other)
      assert_equal 1, messages.length
    end
  end

  def test_same_incident_expanding_to_another_coding_service_notifies_once
    config = build_config
    messages = []
    service = scoped_service
    TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", {}, service)
      service[:services] << { id: "cli", name: "Codex CLI", state: "degraded" }
      service[:incidents].first[:componentIds] << "cli"
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, service)
      TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, service)
      assert_equal 2, messages.length
      assert_includes messages.last, "Codex CLI"
    end
  end

  def test_mixed_incident_recovery_tracks_coding_components_not_other_services
    config = build_config
    messages = []
    TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
      mixed = scoped_service
      mixed[:incidents].first.merge!(scope: "mixed", currentComponentIds: ["api", "connector"], componentIds: ["api", "connector"])
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", {}, mixed)
      assert_equal ["api"], outstanding.fetch("incident:incident-a")[:componentIds]
      recovered = scoped_service(state: "ok")
      assert_empty TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, recovered)
      assert_equal 2, messages.length
      assert_includes messages.last, "recovered"
    end
  end

  def test_incident_enrichment_loss_and_return_do_not_repeat_the_same_component_alert
    config = build_config
    messages = []
    TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
      service = scoped_service.merge(incidents: [])
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", {}, service)
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, scoped_service)
      assert_equal ["incident:incident-a"], outstanding.keys
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, service)
      TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, scoped_service)
      assert_equal 1, messages.length
    end
  end

  def test_failed_notification_delivery_does_not_acknowledge_impact
    TokenMaxx::Runtime::Notifications.stub(:notify, ->(*) { nil }) do
      assert_empty TokenMaxx::Runtime::Notifications.notify_service_impacts(build_config, "codex", {}, scoped_service)
    end
  end

  def test_component_health_can_alert_without_an_incident_and_partial_recovery_stays_partial
    config = build_config
    messages = []
    service = scoped_service.merge(incidents: [])
    TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", {}, service)
      assert outstanding.key?("component:api")
      partial = scoped_service(state: "unknown").merge(coverage: "partial", incidents: [], services: [{ id: "api", state: "ok" }])
      assert_equal outstanding, TokenMaxx::Runtime::Notifications.notify_service_impacts(config, "codex", outstanding, partial)
      assert_equal 1, messages.length
    end
  end

  def test_notified_identity_survives_disk_roundtrip_unknown_and_disabled_providers
    Dir.mktmpdir("tokenmaxx-notifications") do |dir|
      now = Time.now.utc
      config = with_provider_state(build_config, "codex", enabled: true)
      config[:runtime][:stateDir] = dir
      config[:notifications][:enabled] = true
      config[:notifications][:quotaWarnings] = false
      service = scoped_service
      snapshot = { serviceStatus: { providers: { "codex" => service } }, results: {} }
      messages = []
      TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
        TokenMaxx::Runtime::Notifications.process(config, nil, snapshot, now: now)
        TokenMaxx::Runtime::Notifications.process(config, snapshot, snapshot, now: now)
        assert_equal 1, messages.length
        snapshot[:serviceStatus][:providers]["codex"] = { state: "ok" }
        TokenMaxx::Runtime::Notifications.process(config, snapshot, snapshot, now: now)
        assert_equal 1, messages.length
        snapshot[:serviceStatus][:providers]["codex"] = scoped_service(state: "ok")
        TokenMaxx::Runtime::Notifications.process(config, snapshot, snapshot, now: now)
        assert_equal 2, messages.length
        config = with_provider_state(config, "codex", enabled: false)
        snapshot[:serviceStatus][:providers]["codex"] = scoped_service(id: "new-impact")
        TokenMaxx::Runtime::Notifications.process(config, snapshot, snapshot, now: now)
        assert_equal 2, messages.length
      end
    end
  end

  def test_notifications_fire_on_quota_warning_and_recovery_once
    Dir.mktmpdir("tokenmaxx-state") do |dir|
      now = Time.now.utc
      config = build_config
      config[:runtime][:stateDir] = dir
      config[:notifications][:enabled] = true
      config = with_provider_state(config, "codex", enabled: true, visible: true)
      warning_snapshot = TokenMaxx::Runtime::State.build_snapshot(
        config,
        %w[codex],
        {
          "codex" => provider_result(
            provider: "codex",
            usage: usage_payload(provider: "codex", now: now, primary: window(used_percent: 90, window_minutes: 300, now: now, resets_in_minutes: 120))
          )
        },
        now
      )
      recovered_snapshot = TokenMaxx::Runtime::State.build_snapshot(
        config,
        %w[codex],
        {
          "codex" => provider_result(
            provider: "codex",
            usage: usage_payload(provider: "codex", now: now, primary: window(used_percent: 20, window_minutes: 300, now: now, resets_in_minutes: 120))
          )
        },
        now
      )
      messages = []

      TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
        TokenMaxx::Runtime::Notifications.process(config, nil, warning_snapshot, now: now)
        TokenMaxx::Runtime::Notifications.process(config, warning_snapshot, warning_snapshot, now: now)
        TokenMaxx::Runtime::Notifications.process(config, warning_snapshot, recovered_snapshot, now: now)
      end

      assert_equal 2, messages.length
      assert_includes messages.first, "critical"
      assert_includes messages.last, "recovered"
    end
  end
end
