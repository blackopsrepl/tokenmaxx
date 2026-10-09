# frozen_string_literal: true

require_relative "test_helper"

class RuntimeTest < Minitest::Test
  def test_build_snapshot_generates_view_counts_and_provider_badges
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "codex", enabled: true, visible: true, showInOverview: true)
    config = with_provider_state(config, "claude", enabled: true, visible: false, showInOverview: false, allowAutoSelect: false)
    config = with_provider_state(config, "gemini", enabled: false, visible: true)
    config = TokenMaxx::Core::Config.set_selected_provider(config, "codex")

    results = {
      "codex" => provider_result(
        provider: "codex",
        usage: usage_payload(
          provider: "codex",
          now: now,
          primary: window(used_percent: 5, window_minutes: 300, now: now, resets_in_minutes: 240),
          secondary: window(used_percent: 24, window_minutes: 10_080, now: now, resets_in_minutes: 6_000)
        ),
        credits: { remaining: 3.0, updatedAt: now.iso8601 }
      ),
      "claude" => provider_result(
        provider: "claude",
        error: "Claude OAuth error: HTTP 403"
      )
    }

    service_status = {
      generatedAt: now.iso8601,
      providers: {
        "codex" => { state: "ok", description: "Service operational", updatedAt: now.iso8601 },
        "claude" => { state: "degraded", description: "Claude Code degraded", updatedAt: now.iso8601 }
      }
    }
    history = {
      generatedAt: now.iso8601,
      providers: {
        "codex" => {
          daily: [
            {
              date: now.strftime("%Y-%m-%d"),
              latestPrimaryUsedPercent: 42.0,
              latestSecondaryUsedPercent: 24.0,
              totalTokens: 12_345,
              records: 7
            }
          ]
        }
      }
    }
    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[codex claude], results, now, service_status: service_status, history: history)
    summary = snapshot.dig(:view, :summary)
    codex_view = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "codex" }
    claude_view = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "claude" }

    assert_equal 3, snapshot[:snapshotVersion]
    assert_equal %w[codex claude], snapshot[:enabledProviders]
    assert_equal %w[codex], snapshot[:visibleProviders]
    assert_equal %w[claude], snapshot[:hiddenProviders]
    assert_equal "codex", snapshot[:displayProvider]
    assert_equal 2, summary[:activeCount]
    assert_equal 1, summary[:visibleCount]
    assert_equal 1, summary[:hiddenCount]
    assert_includes codex_view[:badges], "display"
    assert_includes claude_view[:badges], "hidden"
    assert_equal "error", claude_view[:status]
    assert_equal "Service operational", codex_view[:serviceStatusText]
    assert_equal "1 retained days / 12.3k local tokens / 42% peak quota", codex_view[:historySummary]
    assert_equal 42.0, codex_view[:historyDays].first[:barPercent]
    assert_equal "12.3k tok / 7 records", codex_view[:historyDays].first[:detail]
    heatmap = codex_view[:historyHeatmap]
    assert heatmap[:available]
    assert_equal 12_345, heatmap[:totalTokens]
    assert_equal 7, heatmap[:rows].length
    day_cells = heatmap[:rows].flat_map { |row| row[:cells] }.reject { |cell| cell[:empty] }
    assert_equal 1, day_cells.length
    assert_equal 4, day_cells.first[:intensity]
    assert_equal true, day_cells.first[:present]
  end

  def test_peak_view_contract_exposes_timelines_and_schedule_ids
    now = Time.utc(2026, 9, 29, 9, 0)
    config = build_config
    config = with_provider_state(config, "zai", enabled: true, visible: true, showInOverview: true)
    results = {
      "zai" => provider_result(
        provider: "zai",
        usage: usage_payload(
          provider: "zai",
          now: now,
          primary: window(used_percent: 12, window_minutes: 300, now: now, resets_in_minutes: 180),
          secondary: window(used_percent: 34, window_minutes: 10_080, now: now, resets_in_minutes: 5_400)
        )
      )
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[zai], results, now)
    view = snapshot[:view]

    schedules = view[:peakSchedules]
    assert_equal ["ollama:deepseek", "opencode:deepseek", "zai"], schedules.keys.sort
    transitions = schedules.fetch("zai")[:transitions]
    assert transitions.length > 2
    assert_equal 0, transitions.first[1]
    assert transitions.each_cons(2).all? { |first, second| first[0] < second[0] }
    assert transitions.each_cons(2).all? { |first, second| first[1] != second[1] }

    zai_view = view[:providers].find { |entry| entry[:id] == "zai" }
    peak = zai_view[:peak]
    refute_nil peak
    assert_equal "zai", peak[:scheduleId]
    assert_equal "peak", peak[:state]
    assert_equal "Peak", peak[:label]
    assert peak[:windowText].to_s.include?("\u2013")

    peak_card = zai_view[:detailCards].find { |card| card[:key] == "peak" }
    refute_nil peak_card
    assert_equal "zai", peak_card[:scheduleId]

    codex_view = view[:providers].find { |entry| entry[:id] == "codex" }
    assert_nil codex_view[:peak]
  end

  def test_history_heatmap_buckets_tokens_and_aligns_week_rows
    history = {
      generatedAt: "2026-08-09T12:00:00Z",
      providers: {
        "codex" => {
          daily: [
            { date: "2026-08-03", totalTokens: 4_000, records: 2 },
            { date: "2026-08-04", totalTokens: 10_000, records: 3 },
            { date: "2026-08-06", latestPrimaryUsedPercent: 12.0 },
            { date: "2026-08-07", totalTokens: 30_000, records: 9 },
            { date: "2026-08-09", totalTokens: 5_000, records: 1 }
          ]
        }
      }
    }

    heatmap = TokenMaxx::Runtime::Presenter.history_heatmap_view(history.dig(:providers, "codex"))

    assert heatmap[:available]
    assert_equal 49_000, heatmap[:totalTokens]
    assert_equal "49k tok", heatmap[:totalText]
    assert_equal 7, heatmap[:rows].length
    heatmap[:rows].each { |row| assert_equal 2, row[:cells].length }

    sunday_row = heatmap[:rows][0][:cells]
    assert sunday_row[0][:empty]
    assert_equal "2026-08-09", sunday_row[1][:date]
    assert_equal 1, sunday_row[1][:intensity]
    assert_equal true, sunday_row[1][:present]

    monday_row = heatmap[:rows][1][:cells]
    assert_equal "2026-08-03", monday_row[0][:date]
    assert_equal 1, monday_row[0][:intensity]
    assert_equal true, monday_row[0][:present]
    assert monday_row[1][:empty]

    tuesday = heatmap[:rows][2][:cells][0]
    assert_equal "2026-08-04", tuesday[:date]
    assert_equal 2, tuesday[:intensity]
    assert_equal true, tuesday[:present]

    wednesday = heatmap[:rows][3][:cells][0]
    assert_equal "2026-08-05", wednesday[:date]
    refute wednesday[:empty]
    assert_equal 0, wednesday[:intensity]
    assert_equal "", wednesday[:tooltipText]
    assert_equal false, wednesday[:present]

    thursday = heatmap[:rows][4][:cells][0]
    assert_equal "2026-08-06", thursday[:date]
    assert_equal 0, thursday[:intensity]
    assert_equal true, thursday[:present]
    assert_includes thursday[:tooltipText], "12% quota"

    friday = heatmap[:rows][5][:cells][0]
    assert_equal "2026-08-07", friday[:date]
    assert_equal 4, friday[:intensity]
    assert_includes friday[:tooltipText], "30k tok"
    assert_includes friday[:tooltipText], "9 records"

    stats = heatmap[:stats]
    assert_equal 4, stats[:activeDays]
    assert_equal 1, stats[:currentStreak]
    assert_equal "Aug 7", stats[:bestDayText]
    assert_equal "30k tok", stats[:bestCountText]
    assert_equal "Aug 3 - Aug 9", stats[:windowText]
  end

  def test_history_heatmap_reports_unavailable_without_days
    heatmap = TokenMaxx::Runtime::Presenter.history_heatmap_view({ provider: "codex", daily: [] })

    refute heatmap[:available]
    assert_equal [], heatmap[:rows]
    assert_equal "0 tok", heatmap[:totalText]
  end

  def test_cumulative_heatmap_sums_providers_and_keeps_shared_days
    history = {
      generatedAt: "2026-08-09T12:00:00Z",
      providers: {
        "codex" => {
          daily: [
            { date: "2026-08-03", totalTokens: 4_000, records: 2 },
            { date: "2026-08-04", totalTokens: 10_000, records: 3 }
          ]
        },
        "opencode" => {
          daily: [
            { date: "2026-08-03", totalTokens: 9_000, records: 5, latestPrimaryUsedPercent: 44.0 },
            { date: "2026-08-05", totalTokens: 0, records: 0, latestSecondaryUsedPercent: 81.0 }
          ]
        },
        "zai" => {
          daily: [
            { date: "2026-08-06", totalTokens: 2_000, records: 1 }
          ]
        }
      }
    }

    heatmap = TokenMaxx::Runtime::Presenter.cumulative_heatmap_view(history)

    assert heatmap[:available]
    assert_equal 25_000, heatmap[:totalTokens]
    cells = heatmap[:rows].flat_map { |row| row[:cells] }.reject { |cell| cell[:empty] }
    by_date = cells.each_with_object({}) { |cell, map| map[cell[:date]] = cell }

    monday = by_date["2026-08-03"]
    assert_equal 4, monday[:intensity]
    assert_equal true, monday[:present]
    assert_includes monday[:tooltipText], "13k tok"
    assert_includes monday[:tooltipText], "7 records"
    assert_includes monday[:tooltipText], "44% quota"

    tuesday = by_date["2026-08-04"]
    assert_equal 4, tuesday[:intensity]
    assert_equal true, tuesday[:present]

    wednesday = by_date["2026-08-05"]
    assert_equal 0, wednesday[:intensity]
    assert_equal true, wednesday[:present]
    assert_includes wednesday[:tooltipText], "81% quota"

    thursday = by_date["2026-08-06"]
    assert_equal 1, thursday[:intensity]

    assert_equal 3, heatmap[:stats][:activeDays]
  end

  def test_waybar_payload_contains_provider_metric_and_partial_classes
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "codex", enabled: true, visible: true)
    config = with_provider_state(config, "claude", enabled: true, visible: false, allowAutoSelect: false)
    config = with_provider_state(config, "gemini", enabled: false, visible: true)
    config = TokenMaxx::Core::Config.set_selected_provider(config, "codex")

    results = {
      "codex" => provider_result(
        provider: "codex",
        usage: usage_payload(
          provider: "codex",
          now: now,
          primary: window(used_percent: 5, window_minutes: 300, now: now, resets_in_minutes: 240),
          secondary: window(used_percent: 24, window_minutes: 10_080, now: now, resets_in_minutes: 6_000)
        )
      ),
      "claude" => provider_result(
        provider: "claude",
        error: "Claude OAuth error: HTTP 403"
      )
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[codex claude], results, now)
    payload = TokenMaxx::Runtime::Waybar.payload(config, snapshot, now)
    codex_view = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "codex" }

    assert_equal "󰚩 95%  76%", payload[:text]
    assert_equal "5h 95% / W 76%", codex_view[:quotaSummaryText]
    assert_equal %w[primary secondary], codex_view[:metrics].map { |metric| metric[:key] }
    assert_includes payload[:class], "provider-codex"
    assert_includes payload[:class], "partial"
    refute_includes payload[:class], "pace-reserve"
    assert_includes payload[:tooltip], "Display: 󰚩 Codex"
  end

  def test_tooltip_provider_line_surfaces_provider_error_detail
    line = TokenMaxx::Runtime::Presenter.tooltip_provider_line(
      build_config,
      "gemini",
      nil,
      provider_result(provider: "gemini", error: "Gemini quota request failed with HTTP 403: SUBSCRIPTION_REQUIRED")
    )

    assert_includes line, "Gemini quota request failed with HTTP 403"
    assert_includes line, "SUBSCRIPTION_REQUIRED"
  end

  def test_waybar_payload_renders_lone_weekly_window_once
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "codex", enabled: true, visible: true)
    config = TokenMaxx::Core::Config.set_selected_provider(config, "codex")
    results = {
      "codex" => provider_result(
        provider: "codex",
        usage: usage_payload(
          provider: "codex",
          now: now,
          secondary: window(used_percent: 7, window_minutes: 10_080, now: now, resets_in_minutes: 6_000)
        )
      )
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[codex], results, now)
    payload = TokenMaxx::Runtime::Waybar.payload(config, snapshot, now)

    assert_equal "󰚩  93%", payload[:text]
    assert_includes payload[:tooltip], "Weekly 93% left"
    assert_equal 1, payload[:tooltip].scan("Weekly 93% left").length
    refute_includes payload[:tooltip], "5-hour"
  end

  def test_waybar_and_modal_surface_an_expected_but_unreported_five_hour_window
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "codex", enabled: true, visible: true)
    config = TokenMaxx::Core::Config.set_selected_provider(config, "codex")
    usage = usage_payload(
      provider: "codex",
      now: now,
      secondary: window(used_percent: 7, window_minutes: 10_080, now: now, resets_in_minutes: 6_000)
    ).merge(unavailableWindows: ["primary"])
    results = { "codex" => provider_result(provider: "codex", usage: usage) }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[codex], results, now)
    payload = TokenMaxx::Runtime::Waybar.payload(config, snapshot, now)
    codex_view = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "codex" }

    assert_equal "󰚩 --  93%", payload[:text]
    assert_includes payload[:tooltip], "5-hour unavailable"
    assert_equal "5h -- / W 93%", codex_view[:quotaSummaryText]
    assert_equal "Unavailable", codex_view[:detailCards].find { |card| card[:key] == "primary-unavailable" }[:value]
  end

  def test_overview_summary_is_equivalent_across_providers
    now = Time.now.utc
    config = build_config
    results = {
      "codex" => provider_result(
        provider: "codex",
        usage: usage_payload(
          provider: "codex",
          now: now,
          primary: window(used_percent: 3, window_minutes: 300, now: now, resets_in_minutes: 240),
          secondary: window(used_percent: 6, window_minutes: 10_080, now: now, resets_in_minutes: 6_000)
        )
      ),
      "opencode" => provider_result(
        provider: "opencode",
        usage: usage_payload(
          provider: "opencode",
          now: now,
          primary: window(used_percent: 9, window_minutes: 300, now: now, resets_in_minutes: 240),
          secondary: window(used_percent: 27, window_minutes: 10_080, now: now, resets_in_minutes: 6_000),
          tertiary: window(used_percent: 13, window_minutes: 43_200, now: now, resets_in_minutes: 40_000)
        )
      ),
      "gemini" => provider_result(
        provider: "gemini",
        usage: usage_payload(
          provider: "gemini",
          now: now,
          meters: [
            { key: "model:gemini-2.5-flash", label: "gemini-2.5-flash", shortLabel: "2.5-flash", usedPercent: 12.0 },
            { key: "model:gemini-2.5-pro", label: "gemini-2.5-pro", shortLabel: "2.5-pro", usedPercent: 34.0 }
          ]
        )
      )
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[codex opencode gemini], results, now)
    views = snapshot.dig(:view, :providers).each_with_object({}) { |entry, acc| acc[entry[:id]] = entry }

    assert_equal "5h 97% / W 94%", views["codex"][:quotaSummaryText]
    assert_equal "5h 91% / W 73%", views["opencode"][:quotaSummaryText]
    assert_equal "2.5-pro 66%", views["gemini"][:quotaSummaryText]
  end

  def test_daemon_retains_cached_usage_after_refresh_failure
    now = Time.now.utc
    cached_usage = usage_payload(
      provider: "codex",
      now: now,
      primary: window(used_percent: 11, window_minutes: 300, now: now, resets_in_minutes: 240)
    )
    previous = {
      results: {
        "codex" => provider_result(provider: "codex", usage: cached_usage, credits: { remaining: 2 })
      }
    }
    failed = {
      "codex" => provider_result(provider: "codex", error: "Codex app-server closed stdout")
    }

    retained = TokenMaxx::Runtime::Daemon.retain_cached_usage(failed, previous).fetch("codex")

    assert_same cached_usage, retained[:usage]
    assert_equal({ remaining: 2 }, retained[:credits])
    assert_equal "Codex app-server closed stdout", retained[:error]
    assert_includes retained[:notes], "Showing last cached quota after refresh failure."
  end

  def test_waybar_payload_includes_service_outage_class
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "codex", enabled: true, visible: true)
    config = TokenMaxx::Core::Config.set_selected_provider(config, "codex")
    results = {
      "codex" => provider_result(
        provider: "codex",
        usage: usage_payload(
          provider: "codex",
          now: now,
          primary: window(used_percent: 5, window_minutes: 300, now: now, resets_in_minutes: 240)
        )
      )
    }
    service_status = {
      providers: {
        "codex" => { state: "outage", description: "Codex API outage", updatedAt: now.iso8601 }
      }
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[codex], results, now, service_status: service_status)
    payload = TokenMaxx::Runtime::Waybar.payload(config, snapshot, now)

    assert_includes payload[:class], "service-outage"
  end

  def test_gemini_model_buckets_render_as_separate_meters
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "codex", enabled: true, visible: true)
    config = with_provider_state(config, "gemini", enabled: true, visible: true)
    results = {
      "codex" => provider_result(
        provider: "codex",
        usage: usage_payload(provider: "codex", now: now, primary: window(used_percent: 14, window_minutes: 300, now: now, resets_in_minutes: 120))
      ),
      "gemini" => provider_result(
        provider: "gemini",
        usage: usage_payload(
          provider: "gemini",
          now: now,
          meters: [
            { key: "model:gemini-2.5-flash", label: "gemini-2.5-flash", shortLabel: "2.5-flash", modelId: "gemini-2.5-flash", usedPercent: 0.0, remainingPercent: 100.0, resetsAt: (now + 3600).iso8601 },
            { key: "model:gemini-2.5-pro", label: "gemini-2.5-pro", shortLabel: "2.5-pro", modelId: "gemini-2.5-pro", usedPercent: 100.0, remainingPercent: 0.0, resetsAt: nil },
            { key: "model:gemini-3.1-flash-lite-preview", label: "gemini-3.1-flash-lite-preview", shortLabel: "3.1-flash-lite-preview", modelId: "gemini-3.1-flash-lite-preview", usedPercent: 0.2, remainingPercent: 99.8, resetsAt: (now + 7200).iso8601 }
          ]
        )
      )
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[codex gemini], results, now)
    gemini = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "gemini" }
    payload = TokenMaxx::Runtime::Waybar.payload(config, snapshot, now)

    assert_equal "gemini", snapshot[:displayProvider]
    assert_equal ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3.1-flash-lite-preview"], gemini[:metrics].map { |metric| metric[:label] }
    assert_equal "gemini-2.5-pro", gemini[:dominantMetric][:label]
    assert_equal "warning", gemini[:status]
    assert_includes payload[:text], "2.5-pro"
    assert_includes payload[:class], "warning"
    refute_includes payload[:class], "critical"
    assert_includes payload[:tooltip], "gemini-3.1-flash-lite-preview"
  end

  def test_unsupported_local_usage_payload_is_reported_as_unsupported_not_pending
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "gemini", enabled: true, visible: true)
    results = {
      "gemini" => provider_result(
        provider: "gemini",
        usage: usage_payload(
          provider: "gemini",
          now: now,
          meters: [
            { key: "model:gemini-2.5-flash", label: "gemini-2.5-flash", usedPercent: 5.0, remainingPercent: 95.0 }
          ]
        )
      )
    }
    local_usage = {
      providers: {
        "gemini" => TokenMaxx::Runtime::LocalUsage.unsupported_provider("gemini")
      }
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[gemini], results, now, local_usage: local_usage)
    gemini = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "gemini" }

    assert_equal "Local usage unsupported", gemini[:localUsageText]
  end

  def test_gemini_local_usage_models_are_exposed_to_the_view
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "gemini", enabled: true, visible: true)
    results = {
      "gemini" => provider_result(
        provider: "gemini",
        usage: usage_payload(
          provider: "gemini",
          now: now,
          meters: [
            { key: "model:gemini-2.5-flash", label: "gemini-2.5-flash", usedPercent: 5.0, remainingPercent: 95.0 }
          ]
        )
      )
    }
    local_usage = {
      providers: {
        "gemini" => {
          provider: "gemini",
          supported: true,
          records: 3,
          totalTokens: 12_345,
          models: {
            "gemini-2.5-flash" => {
              modelId: "gemini-2.5-flash",
              records: 3,
              inputTokens: 10_000,
              cachedInputTokens: 1_000,
              outputTokens: 2_000,
              reasoningOutputTokens: 300,
              toolTokens: 45,
              totalTokens: 12_345
            }
          },
          daily: []
        }
      }
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[gemini], results, now, local_usage: local_usage)
    gemini = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "gemini" }

    assert_equal "12.3k tok · 3 records", gemini[:localUsageText]
    assert_equal "gemini-2.5-flash", gemini[:localUsageModels].first[:modelId]
    assert_equal "12.3k tok", gemini[:localUsageModels].first[:tokensText]
    assert_includes gemini[:localUsageModels].first[:detail], "1k cached"
  end

  def test_local_usage_source_labels_name_each_store
    assert_equal "Sources: OpenCode DB + Hermes",
                 TokenMaxx::Runtime::Presenter.local_usage_sources_text(sources: %w[opencode-db hermes])
    assert_equal "Sources: Codex CLI", TokenMaxx::Runtime::Presenter.local_usage_sources_text(sources: %w[codex-jsonl])
    assert_equal "Sources: bespoke-store",
                 TokenMaxx::Runtime::Presenter.local_usage_sources_text(sources: ["bespoke-store"])
    assert_nil TokenMaxx::Runtime::Presenter.local_usage_sources_text(sources: [])
    assert_nil TokenMaxx::Runtime::Presenter.local_usage_sources_text(nil)
  end

  def test_local_usage_card_detail_names_the_stores_it_covers
    card = TokenMaxx::Runtime::Presenter.local_usage_card(
      supported: true,
      totalTokens: 10,
      records: 1,
      sources: %w[opencode-db hermes]
    )
    plain = TokenMaxx::Runtime::Presenter.local_usage_card(
      supported: true,
      totalTokens: 10,
      records: 1,
      sources: []
    )

    assert_equal "Exact local logs · OpenCode DB + Hermes", card[:detail]
    assert_equal "Exact local logs", plain[:detail]
  end

  def test_provider_view_exposes_local_usage_sources
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "opencode", enabled: true, visible: true)
    results = {
      "opencode" => provider_result(
        provider: "opencode",
        usage: usage_payload(
          provider: "opencode",
          now: now,
          primary: window(used_percent: 3, window_minutes: 300, now: now, resets_in_minutes: 60)
        )
      )
    }
    local_usage = {
      providers: {
        "opencode" => {
          provider: "opencode",
          supported: true,
          records: 5,
          totalTokens: 4_155,
          sources: %w[opencode-db hermes],
          models: {
            "deepseek-v4.1-flash" => {
              modelId: "deepseek-v4.1-flash",
              records: 5,
              totalTokens: 4_155
            }
          },
          daily: []
        }
      }
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[opencode], results, now, local_usage: local_usage)
    opencode = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "opencode" }
    card = opencode[:detailCards].find { |entry| entry[:key] == "local-usage" }

    assert_equal "Sources: OpenCode DB + Hermes", opencode[:localUsageSourcesText]
    assert_equal "Exact local logs · OpenCode DB + Hermes", card[:detail]
  end

  def test_waybar_payload_reports_off_when_no_providers_are_enabled
    config = build_config
    payload = TokenMaxx::Runtime::Waybar.payload(config, nil, Time.now)

    assert_equal "󰚩 off", payload[:text]
    assert_includes payload[:class], "tokenmaxx"
    assert_includes payload[:tooltip], "no providers enabled"
  end

  def test_ollama_monthly_window_summarizes_with_its_own_short_label
    now = Time.now.utc
    config = build_config
    config = with_provider_state(config, "ollama", enabled: true, visible: true)
    results = {
      "ollama" => provider_result(
        provider: "ollama",
        usage: usage_payload(
          provider: "ollama",
          now: now,
          primary: { label: "Monthly", shortLabel: "mo", usedPercent: 88.0, windowMinutes: 43_200, resetsAt: nil, resetDescription: nil }
        ),
        source: "ollama-cloud"
      )
    }

    snapshot = TokenMaxx::Runtime::State.build_snapshot(config, %w[ollama], results, now)
    ollama = snapshot.dig(:view, :providers).find { |entry| entry[:id] == "ollama" }
    payload = TokenMaxx::Runtime::Waybar.payload(config, snapshot, now)

    assert_equal "mo 12%", ollama[:quotaSummaryText]
    assert_equal "Monthly", ollama[:dominantMetric][:label]
    assert_equal "mo", ollama[:dominantMetric][:shortLabel]
    assert_includes payload[:tooltip], "Ollama Cloud"
  end

  def test_history_and_storage_include_the_ollama_provider
    history = TokenMaxx::Runtime::History.normalize_history({}, 30)
    refute_nil history[:providers]
    assert_includes TokenMaxx::Runtime::Storage::PROVIDER_PATHS.keys, "ollama"
  end

  def test_ensure_state_dir_imports_legacy_state_files_once
    Dir.mktmpdir("tokenmaxx-state-migrate") do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      begin
        legacy_dir = File.join(home, ".local", "state", "codexbar")
        FileUtils.mkdir_p(legacy_dir)
        history_payload = "{\"providers\":{}}"
        File.write(File.join(legacy_dir, "history.json"), history_payload)
        File.write(File.join(legacy_dir, "daemon.lock"), "12345\n")

        config = build_config
        config[:runtime][:stateDir] = File.join(home, ".local", "state", "tokenmaxx")

        dir = TokenMaxx::Runtime::State.ensure_state_dir(config)

        assert File.file?(File.join(dir, "history.json")), "history state was not imported"
        assert_equal history_payload, File.read(File.join(dir, "history.json"))
        assert_equal 0o600, File.stat(File.join(dir, "history.json")).mode & 0o777
        refute File.file?(File.join(dir, "daemon.lock")), "legacy locks must never migrate"
        assert File.file?(File.join(legacy_dir, "history.json")), "legacy files must be left in place"

        # No-fallback semantics: after the import, removing the legacy dir
        # must not affect the migrated state dir.
        FileUtils.rm_rf(legacy_dir)
        TokenMaxx::Runtime::State.ensure_ui_state(config)
        assert File.file?(File.join(dir, "ui.json"))
      ensure
        ENV["HOME"] = old_home
      end
    end
  end

  def test_daemon_refresh_keeps_selection_pinned_during_fetch
    Dir.mktmpdir("tokenmaxx-daemon-refresh") do |dir|
      now = Time.now.utc
      config_path = File.join(dir, "config.json")
      config = build_config
      config[:runtime][:stateDir] = dir
      config = with_provider_state(config, "codex", enabled: true, visible: true, showInOverview: true)
      config = with_provider_state(config, "zai", enabled: true, visible: true, showInOverview: true)
      config = TokenMaxx::Core::Config.set_selected_provider(config, "codex")
      TokenMaxx::Core::Config.save_config(config, config_path)

      result = provider_result(
        provider: "codex",
        usage: usage_payload(provider: "codex", now: now, primary: window(used_percent: 10, window_minutes: 300, now: now, resets_in_minutes: 60))
      )

      TokenMaxx::Runtime::Usage.stub(:collect_usage, ->(*, **) {
        # The user pins another provider while the fetch is in flight.
        updated = TokenMaxx::Core::Config.set_selected_provider(
          TokenMaxx::Core::Config.load_config(config_path), "zai"
        )
        TokenMaxx::Core::Config.save_config(updated, config_path)
        { "codex" => result, "zai" => result }
      }) do
        TokenMaxx::Runtime::Status.stub(:refresh_if_due, ->(*) { {} }) do
          TokenMaxx::Runtime::LocalUsage.stub(:refresh_if_due, ->(*) { {} }) do
            TokenMaxx::Runtime::Storage.stub(:refresh_if_due, ->(*) { {} }) do
              TokenMaxx::Runtime::History.stub(:update, ->(*) { {} }) do
                TokenMaxx::Runtime::Notifications.stub(:process, ->(*) { {} }) do
                  TokenMaxx::Runtime::Daemon.stub(:signal_waybar, ->(*) {}) do
                    snapshot = TokenMaxx::Runtime::Daemon.refresh(config_path)
                    assert_equal "zai", snapshot[:displayProvider]
                  end
                end
              end
            end
          end
        end
      end

      reread = TokenMaxx::Runtime::State.read_snapshot(
        TokenMaxx::Core::Config.load_config(config_path)
      )
      assert_equal "zai", reread[:displayProvider]
    end
  end

  def test_ensure_state_dir_never_imports_into_the_legacy_dir_itself
    Dir.mktmpdir("tokenmaxx-state-legacy") do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      begin
        legacy_dir = File.join(home, ".local", "state", "codexbar")
        FileUtils.mkdir_p(legacy_dir)
        File.write(File.join(legacy_dir, "snapshot.json"), "{}")

        config = build_config
        config[:runtime][:stateDir] = legacy_dir

        TokenMaxx::Runtime::State.ensure_state_dir(config)

        assert_equal ["snapshot.json"], Dir.glob(File.join(legacy_dir, "*.json")).map { |p| File.basename(p) }
      ensure
        ENV["HOME"] = old_home
      end
    end
  end
end
