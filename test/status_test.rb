# frozen_string_literal: true

require_relative "test_helper"

class StatusTest < Minitest::Test
  Status = TokenMaxx::Runtime::Status
  Http = TokenMaxx::Core::Http
  NOW = Time.utc(2026, 11, 13, 12)

  def fixture(name)
    JSON.parse(File.read(File.join(__dir__, "fixtures/status/#{name}.json")), symbolize_names: true)
  end

  def response(payload, status: 200)
    Http::Response.new(status: status, body: JSON.generate(payload), headers: {})
  end

  def feeds(overrides = {})
    metadata = TokenMaxx::Core::Types::STATUS_METADATA
    {
      metadata["codex"][:url] => fixture("openai-components"),
      metadata["codex"][:enrichmentUrl] => fixture("openai-native"),
      metadata["codex"][:fallbackUrl] => fixture("openai-summary"),
      metadata["claude"][:url] => fixture("claude-summary")
    }.merge(overrides)
  end

  def fetch(provider, payloads: feeds, previous: nil, now: NOW)
    Http.stub(:request, lambda { |_method, url, **_args|
      value = payloads.fetch(url)
      raise value if value.is_a?(Exception)
      value.is_a?(Http::Response) ? value : response(value)
    }) { Status.fetch_provider(provider, now: now, previous: previous) }
  end

  def claude_payload
    fixture("claude-summary")
  end

  def fetch_claude(payload)
    fetch("claude", payloads: { TokenMaxx::Core::Types::STATUS_METADATA["claude"][:url] => payload })
  end

  # Synthetic scenarios below are mutations of the captured public feed.
  def synthetic_incident(id: "synthetic", ids: [], status: "investigating", title: "Generic errors")
    { id: id, name: title, status: status, impact: "major", components: ids.map { |cid| { id: cid } },
      incident_updates: [{ body: "Plain latest update", created_at: NOW.iso8601 }] }
  end

  def test_captured_openai_full_catalog_not_truncated_summary_establishes_coding_health
    assert_equal 37, fixture("openai-components")[:components].size
    assert_equal 25, fixture("openai-summary")[:components].size
    record = fetch("codex")
    assert_equal "ok", record[:state]
    assert_equal "complete", record[:coverage]
    assert_equal "complete", record[:incidentCoverage]
    assert_equal %w[Codex\ API Codex\ CLI], record[:services].map { |s| s[:name] }
    assert_equal ["other"], record[:incidents].map { |i| i[:scope] }
    assert_equal "degraded", record[:incidents].first[:state]
    assert_nil record[:incident]
    refute_includes record[:description], "Microsoft"
  end

  def test_captured_claude_connector_does_not_affect_coding
    record = fetch("claude")
    assert_equal "ok", record[:state]
    assert_equal "complete", record[:coverage]
    assert_equal "other", record[:incidents].first[:scope]
    assert_equal "degraded", record[:incidents].first[:state]
    assert_includes record[:incidents].first[:affectedServices], "claude.ai"
    assert_equal "degraded", record[:vendor][:state]
    assert_nil record[:incident]
  end

  def test_other_incident_impact_is_not_escalated_by_an_unrelated_shared_component_outage
    payload = claude_payload
    payload[:components].find { |component| component[:id] == "rwppv331jlwc" }[:status] = "major_outage"
    payload[:components].find { |component| component[:id] == "bpp5gb3hpjcl" }[:status] = "major_outage"
    record = fetch_claude(payload)
    assert_equal "ok", record[:state]
    assert_equal "other", record[:incidents].first[:scope]
    assert_equal "degraded", record[:incidents].first[:state]
  end

  def test_missing_unknown_duplicate_or_renamed_component_prevents_green
    metadata = TokenMaxx::Core::Types::STATUS_METADATA["claude"]
    id = metadata[:services].first[:id]
    [:missing, :unknown, :duplicate, :renamed].each do |scenario|
      payload = claude_payload
      component = payload[:components].find { |c| c[:id] == id }
      case scenario
      when :missing then payload[:components].delete(component)
      when :unknown then component[:status] = "new_status"
      when :duplicate then payload[:components] << component.dup
      when :renamed then component[:name] = "API"
      end
      record = fetch_claude(payload)
      assert_equal "unknown", record[:state], scenario
      assert_equal "partial", record[:coverage], scenario
      assert_equal "unknown", record[:services].first[:state]
    end
  end

  def test_id_not_title_establishes_coding_or_mixed_impact
    payload = claude_payload
    coding = payload[:components].find { |c| c[:id] == "yyzkbfz2thpt" }
    coding[:status] = "major_outage"
    payload[:incidents] = [synthetic_incident(ids: [coding[:id], "rwppv331jlwc"])]
    record = fetch_claude(payload)
    assert_equal "outage", record[:state]
    assert_equal "mixed", record[:incidents].first[:scope]
    assert_equal "outage", record[:incidents].first[:state]
    assert_equal "Generic errors (investigating)", record[:incident]
  end

  def test_claude_explicit_current_impact_conflicts_with_operational_catalog
    payload = claude_payload
    item = synthetic_incident(ids: ["yyzkbfz2thpt"])
    item[:components].first[:status] = "major_outage"
    item[:incident_updates].first[:affected_components] = [{ code: "yyzkbfz2thpt", new_status: "major_outage" }]
    payload[:incidents] = [item]
    record = fetch_claude(payload)
    assert_equal "outage", record[:state]
    assert_equal "outage", record[:incidents].first[:state]
    assert record[:services].first[:conflict]
    assert_includes record[:description], "conflicting"
  end

  def test_claude_update_impact_is_current_unless_a_later_vendor_component_mutation_supersedes_it
    payload = claude_payload
    component = payload[:components].find { |entry| entry[:id] == "yyzkbfz2thpt" }
    item = synthetic_incident
    item[:incident_updates].first[:affected_components] = [{ code: component[:id], new_status: "major_outage" }]
    payload[:incidents] = [item]
    assert_equal "outage", fetch_claude(payload)[:state]
    component[:updated_at] = (NOW + 1).iso8601
    recovered = fetch_claude(payload)
    assert_equal "ok", recovered[:state]
    assert_equal "ok", recovered[:incidents].first[:state]
  end

  def test_retained_fresh_conflicting_impact_prevents_premature_recovery
    metadata = TokenMaxx::Core::Types::STATUS_METADATA["codex"]
    native = fixture("openai-native")
    native[:summary][:ongoing_incidents].first[:affected_components] = [{ component_id: metadata[:services].first[:id], current_status: "major_outage" }]
    old = fetch("codex", payloads: feeds(metadata[:enrichmentUrl] => native))
    record = fetch("codex", previous: old, now: NOW + 30, payloads: feeds(metadata[:enrichmentUrl] => IOError.new("native unavailable")))
    projected = Status.for_display(record, refresh_seconds: 60, now: NOW + 30)
    assert_equal "outage", projected[:state]
    assert_equal "outage", projected[:incidents].first[:state]
    assert projected[:services].first[:conflict]
    messages = []
    TokenMaxx::Runtime::Notifications.stub(:notify, ->(_config, _title, message) { messages << message }) do
      outstanding = TokenMaxx::Runtime::Notifications.notify_service_impacts(build_config, "codex", {}, Status.for_display(old, refresh_seconds: 60, now: NOW))
      TokenMaxx::Runtime::Notifications.notify_service_impacts(build_config, "codex", outstanding, projected)
    end
    assert_equal 1, messages.length
    refute_includes messages.join, "recovered"
    expired = Status.for_display(record, refresh_seconds: 60, now: NOW + 121)
    assert_equal "unknown", expired[:state]
  end

  def test_title_only_and_unknown_association_are_unconfirmed
    payload = claude_payload
    payload[:incidents] = [synthetic_incident(title: "Claude Code outage"), synthetic_incident(id: "unknown", ids: ["unreviewed-component"])]
    record = fetch_claude(payload)
    assert_equal "ok", record[:state]
    assert_equal ["unconfirmed", "unconfirmed"], record[:incidents].map { |i| i[:scope] }
    assert record[:incidents].all? { |i| i[:state] == "unknown" }
    assert_nil record[:incident]
  end

  def test_monitoring_operational_components_is_not_degradation
    payload = claude_payload
    payload[:incidents] = [synthetic_incident(ids: ["yyzkbfz2thpt"], status: "monitoring")]
    record = fetch_claude(payload)
    assert_equal "ok", record[:state]
    assert_equal "coding", record[:incidents].first[:scope]
    assert_equal "ok", record[:incidents].first[:state]
    assert_nil record[:incident]
  end

  def test_historical_update_membership_does_not_assert_current_impact
    payload = claude_payload
    incident = synthetic_incident
    incident[:incident_updates] << { created_at: (NOW - 60).iso8601, affected_components: [{ code: "yyzkbfz2thpt", new_status: "major_outage" }] }
    payload[:incidents] = [incident]
    record = fetch_claude(payload)
    assert_equal "coding", record[:incidents].first[:scope]
    assert_equal [], record[:incidents].first[:currentComponentIds]
    assert_equal ["yyzkbfz2thpt"], record[:incidents].first[:historicalComponentIds]
    assert_equal "unknown", record[:incidents].first[:state]
    assert_equal "ok", record[:state]
  end

  def test_latest_affected_component_code_joins_claude_identity
    payload = claude_payload
    payload[:components].find { |c| c[:id] == "k8w3r06qmzrp" }[:status] = "degraded_performance"
    item = synthetic_incident
    item[:incident_updates].first[:affected_components] = [{ code: "k8w3r06qmzrp", new_status: "degraded_performance" }]
    payload[:incidents] = [item]
    record = fetch_claude(payload)
    assert_equal "coding", record[:incidents].first[:scope]
    assert_equal "degraded", record[:incidents].first[:state]
  end

  def test_scheduled_maintenance_is_not_automatically_outage
    payload = claude_payload
    payload[:scheduled_maintenances] = [synthetic_incident(ids: ["yyzkbfz2thpt"], status: "scheduled")]
    record = fetch_claude(payload)
    assert_equal "ok", record[:state]
    assert_equal "unknown", record[:incidents].find { |i| i[:id] == "synthetic" }[:state]
  end

  def test_wrong_page_200_and_malformed_responses_are_not_success
    payload = claude_payload
    payload[:page][:id] = "wrong-page"
    record = fetch_claude(payload)
    assert_equal "unknown", record[:state]
    assert_match(/page identity/, record[:error])
    assert_nil record[:updatedAt]
    url = TokenMaxx::Core::Types::STATUS_METADATA["claude"][:url]
    record = fetch("claude", payloads: { url => Http::Response.new(status: 200, body: "bad json", headers: {}) })
    assert_equal "unknown", record[:state]
    assert_nil record[:updatedAt]
  end

  def test_enrichment_failure_preserves_independent_complete_health
    meta = TokenMaxx::Core::Types::STATUS_METADATA["codex"]
    record = fetch("codex", payloads: feeds(meta[:enrichmentUrl] => IOError.new("enrichment down")))
    assert_equal "ok", record[:state]
    assert_equal "complete", record[:coverage]
    assert_equal "partial", record[:incidentCoverage]
    assert record[:incidents].all? { |i| i[:scope] == "unconfirmed" }
    assert_equal NOW.iso8601, record[:updatedAt]
  end

  def test_source_specific_last_good_does_not_advance_success_time
    old = fetch("codex")
    meta = TokenMaxx::Core::Types::STATUS_METADATA["codex"]
    record = fetch("codex", previous: old, now: NOW + 30,
                   payloads: feeds(meta[:url] => IOError.new("health down")))
    assert_equal old[:updatedAt], record[:updatedAt]
    assert_equal (NOW + 30).iso8601, record[:checkedAt]
    assert_equal NOW.iso8601, record[:services].first[:checkedAt]
    assert_equal (NOW + 30).iso8601, record[:sources].find { |s| s[:kind] == "incidents" }[:lastSuccessAt]
    assert_equal "ok", Status.for_display(record, refresh_seconds: 60, now: NOW + 119)[:state]
    expired = Status.for_display(record, refresh_seconds: 60, now: NOW + 120)
    assert_equal "unknown", expired[:state]
    assert_equal "ok", expired[:lastKnownState]
    assert_equal "stale", expired[:freshness]
    assert_equal "unknown", expired[:services].first[:state]
    assert_equal NOW.iso8601, expired[:updatedAt]
    assert_equal "ok", record[:state], "display must not mutate the cache"
  end

  def test_failed_incident_refresh_retains_original_incident_timestamp
    old = fetch("codex")
    meta = TokenMaxx::Core::Types::STATUS_METADATA["codex"]
    record = fetch("codex", previous: old, now: NOW + 121,
                   payloads: feeds(meta[:enrichmentUrl] => IOError.new("down")))
    assert_equal NOW.iso8601, record[:incidents].first[:checkedAt]
    display = Status.for_display(record, refresh_seconds: 60, now: NOW + 121)
    assert_equal "ok", display[:state]
    assert_equal "stale", display[:incidents].first[:freshness]
    assert_equal "unavailable", display[:incidentCoverage]
    assert_equal (NOW + 120).iso8601, display[:incidentStaleAt]
  end

  def test_openai_wrong_page_component_feed_never_uses_global_state
    meta = TokenMaxx::Core::Types::STATUS_METADATA["codex"]
    payload = fixture("openai-components")
    payload[:components].first[:page_id] = "wrong-page"
    record = fetch("codex", payloads: feeds(meta[:url] => payload))
    assert_equal "unknown", record[:state]
    assert_equal "unavailable", record[:coverage]
    assert_match(/page identity/, record[:error])
  end

  def test_current_openai_impact_conflict_retains_impact_and_missing_coverage
    meta = TokenMaxx::Core::Types::STATUS_METADATA["codex"]
    payload = fixture("openai-native")
    item = payload[:summary][:ongoing_incidents].first
    id = meta[:services].first[:id]
    item[:affected_components] = [{ component_id: id, current_status: "major_outage" }]
    record = fetch("codex", payloads: feeds(meta[:enrichmentUrl] => payload))
    assert_equal "outage", record[:state]
    assert_equal true, record[:services].first[:conflict]
    assert_equal "outage", record[:incidents].first[:state]
    assert_includes record[:description], "conflicting"
  end

  def test_legacy_cache_is_unknown_without_network_or_claim_of_recovery
    Http.stub(:request, ->(*) { flunk "display must not fetch" }) do
      value = Status.for_display({ state: "outage", incident: "Vendor global", updatedAt: NOW.iso8601 }, refresh_seconds: 60, now: NOW)
      assert_equal "unknown", value[:state]
      assert_equal "unavailable", value[:coverage]
      assert_equal "Awaiting scoped status refresh", value[:description]
      assert_empty value[:incidents]
      assert_nil value[:updatedAt]
    end
  end

  def test_per_service_expiration_is_independent_of_generated_record_time
    record = fetch("claude")
    record[:services].first[:checkedAt] = (NOW - 121).iso8601
    display = Status.for_display(record, refresh_seconds: 60, now: NOW)
    assert_equal "unknown", display[:state]
    assert_equal "unknown", display[:services].first[:state]
    assert_equal "ok", display[:services].last[:state]
  end

  def test_vendor_text_is_plain_and_vendor_links_allowlisted
    payload = claude_payload
    item = synthetic_incident(ids: ["yyzkbfz2thpt"], title: "<script>bad</script> Title")
    item[:url] = "https://evil.example/trick"
    item[:incident_updates].first[:body] = "<b>Latest</b>\n update"
    payload[:incidents] = [item]
    record = fetch_claude(payload)
    assert_equal "bad Title", record[:incidents].first[:title]
    assert_equal "Latest update", record[:incidents].first[:updateText]
    assert_equal "https://status.claude.com/incidents/synthetic", record[:incidents].first[:url]
  end

  def test_gemini_product_attribution_is_not_a_cli_or_global_health_guarantee
    url = TokenMaxx::Core::Types::STATUS_METADATA["gemini"][:url]
    payload = [{ id: "synthetic-google", end: nil, status: "SERVICE_DISRUPTION", external_desc: "Vertex errors", affected_products: [{ title: "Vertex Gemini API" }] }]
    record = fetch("gemini", payloads: { url => payload })
    assert_equal "degraded", record[:state]
    assert_equal "partial", record[:coverage]
    assert_equal "Vertex Gemini API", record[:services].first[:name]
    assert_includes record[:description], "not Gemini CLI"
    assert_equal ["Vertex Gemini API"], record[:incidents].first[:componentIds]
  end

  def test_account_endpoints_never_establish_inference_outage_or_operational
    implementations = { "opencode" => TokenMaxx::Providers::Opencode, "zai" => TokenMaxx::Providers::Zai, "ollama" => TokenMaxx::Providers::Ollama }
    implementations.each do |provider, implementation|
      implementation.stub(:resolve_api_key, "synthetic-key") do
        [200, 401, 403, 429, 500, 503].each do |code|
          payload = case provider
                    when "opencode" then { usage: { rolling: { percent: 20 } } }
                    when "zai" then { data: { limits: [{ type: "TOKENS_LIMIT", unit: 3, percentage: 20 }] } }
                    else { included: { balance_usd: 17.35, allowance_usd: 60 } }
                    end
          Http.stub(:request, response(payload, status: code)) do
            record = Status.fetch_provider(provider, now: NOW)
            assert_equal "unknown", record[:state], "#{provider} HTTP #{code}"
            assert_equal "unavailable", record[:coverage]
            assert_equal code == 200 ? "ok" : "error", record[:observation][:state]
            assert_nil record[:updatedAt]
            assert_match(/authentication/, record[:observation][:error]) if [401, 403].include?(code)
            assert_match(/rate limit/, record[:observation][:error]) if code == 429
          end
        end
      end
    end
  end

  def test_explicit_claude_current_component_impact_survives_missing_catalog_entry
    payload = claude_payload
    payload[:components].reject! { |component| component[:id] == "yyzkbfz2thpt" }
    incident = synthetic_incident(ids: ["yyzkbfz2thpt"])
    incident[:components].first[:status] = "major_outage"
    payload[:incidents] = [incident]
    record = fetch_claude(payload)
    assert_equal "outage", record[:state]
    assert_equal "partial", record[:coverage]
    assert_equal "outage", record[:incidents].first[:state]
    assert_includes record[:missingServices], "yyzkbfz2thpt"
  end

  def test_display_is_idempotent_for_legacy_fresh_partial_and_stale_records
    record = fetch("claude")
    records = [{ state: "outage", updatedAt: NOW.iso8601 }, record]
    partial = Marshal.load(Marshal.dump(record))
    partial[:services].first[:checkedAt] = (NOW - 121).iso8601
    records << partial
    records.each do |item|
      [NOW, NOW + 121].each do |time|
        first = Status.for_display(item, refresh_seconds: 60, now: time)
        second = Status.for_display(first, refresh_seconds: 60, now: time)
        assert_equal first, second
      end
    end
  end

  def test_fresh_incident_cannot_refresh_expired_component_status
    payload = claude_payload
    payload[:incidents] = [synthetic_incident(ids: ["yyzkbfz2thpt"])]
    record = fetch_claude(payload)
    record[:services].first[:checkedAt] = (NOW - 121).iso8601
    projected = Status.for_display(record, refresh_seconds: 60, now: NOW)
    assert_equal "unknown", projected[:incidents].first[:state]
    assert_equal "partial", projected[:coverage]
    assert_includes projected[:description], "stale"
  end

  def test_current_native_coding_impact_establishes_partial_health_without_component_catalog
    metadata = TokenMaxx::Core::Types::STATUS_METADATA["codex"]
    native = fixture("openai-native")
    native[:summary][:ongoing_incidents].first[:affected_components] = [{ component_id: metadata[:services].first[:id], current_status: "major_outage" }]
    record = fetch("codex", payloads: feeds(metadata[:url] => IOError.new("health unavailable"), metadata[:enrichmentUrl] => native))
    assert_equal "outage", record[:state]
    assert_equal "partial", record[:coverage]
    assert_equal NOW.iso8601, record[:updatedAt]
    projected = Status.for_display(record, refresh_seconds: 60, now: NOW)
    assert_equal "outage", projected[:state]
    assert_equal "partial", projected[:coverage]
    expired = Status.for_display(record, refresh_seconds: 60, now: NOW + 120)
    assert_equal "unknown", expired[:state]
    assert_equal "stale", expired[:freshness]
  end

  def test_account_last_good_observation_and_success_time_survive_failure
    implementation = TokenMaxx::Providers::Ollama
    implementation.stub(:resolve_api_key, "synthetic-key") do
      good = nil
      Http.stub(:request, response({ included: { balance_usd: 10, allowance_usd: 20 } })) do
        good = Status.fetch_provider("ollama", now: NOW)
      end
      Http.stub(:request, response({}, status: 401)) do
        failed = Status.fetch_provider("ollama", now: NOW + 30, previous: good)
        assert_equal "error", failed[:observation][:state]
        assert_equal "ok", failed[:observation][:lastGood][:state]
        assert_equal NOW.iso8601, failed[:observation][:lastGood][:checkedAt]
        assert_equal NOW.iso8601, failed[:sources].first[:lastSuccessAt]
        projected = Status.for_display(failed, refresh_seconds: 60, now: NOW + 151)
        assert_equal "stale", projected[:observation][:freshness]
        assert_equal projected, Status.for_display(projected, refresh_seconds: 60, now: NOW + 151)
      end
    end
  end

  def test_gemini_current_update_overrides_historical_impact
    url = TokenMaxx::Core::Types::STATUS_METADATA["gemini"][:url]
    payload = [{ id: "synthetic-google", end: nil, status_impact: "SERVICE_OUTAGE", most_recent_update: { status: "AVAILABLE" }, affected_products: [{ title: "Vertex Gemini API" }] }]
    record = fetch("gemini", payloads: { url => payload })
    assert_equal "unknown", record[:state]
    assert_includes record[:description], "No active advisories"
    assert_empty record[:incidents]
  end

  def test_empty_google_advisory_feed_is_not_proof_of_operational_inference
    url = TokenMaxx::Core::Types::STATUS_METADATA["gemini"][:url]
    record = fetch("gemini", payloads: { url => [] })
    assert_equal "unknown", record[:state]
    assert_equal "partial", record[:coverage]
    assert record[:services].all? { |service| service[:state] == "unknown" }
    assert_includes record[:description], "No active advisories"
  end

  def test_account_malformed_and_timeout_are_observations_not_health
    TokenMaxx::Providers::Ollama.stub(:resolve_api_key, "synthetic-key") do
      [{}, Timeout::Error.new("network timeout")].each do |value|
        Http.stub(:request, lambda { |*args, **kwargs|
          assert_equal TokenMaxx::Providers::Ollama::BALANCE_URL, args[1]
          raise value if value.is_a?(Exception)
          response(value)
        }) do
          record = Status.fetch_provider("ollama", now: NOW)
          assert_equal "unknown", record[:state]
          assert_equal "error", record[:observation][:state]
        end
      end
    end
  end
end
