# frozen_string_literal: true

require_relative "test_helper"

class PeakTest < Minitest::Test
  PEAK = TokenMaxx::Core::Peak

  def test_zai_peaks_weekdays_14_to_18_utc8
    # 2026-09-28 is a Monday. 06:00-10:00 UTC == 14:00-18:00 UTC+8.
    assert_equal "peak", PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 6, 0))[:state]
    assert_equal "peak", PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 9, 59))[:state]
    assert_equal "offpeak", PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 10, 0))[:state]
    assert_equal "offpeak", PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 5, 59))[:state]
    assert_equal "offpeak", PEAK.model_state("zai", nil, Time.utc(2026, 10, 3, 7, 0))[:state]
  end

  def test_ollama_peaks_weekdays_12_to_18_utc_only_for_deepseek_models
    assert_equal "offpeak", PEAK.model_state("ollama", "deepseek-v4.1-flash", Time.utc(2026, 9, 28, 11, 59))[:state]
    assert_equal "peak", PEAK.model_state("ollama", "deepseek-v4.1-flash", Time.utc(2026, 9, 28, 12, 0))[:state]
    assert_equal "offpeak", PEAK.model_state("ollama", "deepseek-v4.1-flash", Time.utc(2026, 9, 28, 18, 0))[:state]
    assert_nil PEAK.model_state("ollama", "gemma4", Time.utc(2026, 9, 28, 13, 0))
  end

  def test_opencode_peaks_only_for_deepseek_models
    assert_equal "peak", PEAK.model_state("opencode", "deepseek-v4-pro", Time.utc(2026, 9, 28, 2, 0))[:state]
    assert_equal "offpeak", PEAK.model_state("opencode", "deepseek-v4-pro", Time.utc(2026, 9, 28, 5, 0))[:state]
    assert_equal "peak", PEAK.model_state("opencode", "deepseek-v4-pro", Time.utc(2026, 9, 28, 7, 0))[:state]
    assert_nil PEAK.model_state("opencode", "kimi-k3", Time.utc(2026, 9, 28, 2, 0))
  end

  def test_deepseek_schedule_scope_excludes_undocumented_models
    %w[ollama opencode].each do |provider|
      %w[deepseek-v3 deepseek-r1 deepseek-v5-pro deepseek-v4-pro-unverified].each do |model|
        assert_nil PEAK.model_state(provider, model, Time.utc(2026, 11, 13, 7)), "#{provider}: #{model}"
      end
    end
    assert_equal "peak", PEAK.model_state("ollama", "deepseek-v4-pro:cloud", Time.utc(2026, 11, 13, 13))[:state]
    assert_equal "peak", PEAK.model_state("ollama", "deepseek-v4.1-flash:1017-cloud", Time.utc(2026, 11, 13, 13))[:state]
    assert_nil PEAK.model_state("opencode", "deepseek-v4-pro:cloud", Time.utc(2026, 11, 13, 7))
  end

  def test_providers_without_time_priced_models_have_no_state
    assert_nil PEAK.model_state("codex", "gpt-5.6-sol", Time.utc(2026, 9, 28, 2, 0))
    assert_nil PEAK.provider_state("codex", ["gpt-5.6-sol"], Time.utc(2026, 9, 28, 2, 0))
    assert_nil PEAK.model_state("claude", "claude-sonnet-4-5", Time.utc(2026, 9, 28, 2, 0))
  end

  def test_model_gated_provider_without_matching_model_has_no_state
    assert_nil PEAK.provider_state("opencode", ["kimi-k3", "glm-5.3"], Time.utc(2026, 9, 28, 2, 0))
    assert_equal "peak", PEAK.provider_state("opencode", ["kimi-k3", "deepseek-v4-pro"], Time.utc(2026, 9, 28, 2, 0))[:state]
  end

  def test_provider_wide_schedule_with_empty_models_still_reports
    state = PEAK.provider_state("zai", [], Time.utc(2026, 9, 28, 7, 0))

    assert_equal "peak", state[:state]
    assert_equal "Peak", state[:label]
    assert_equal [], state[:models]
  end

  def test_detail_text_is_attached
    state = PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 7, 0))

    assert_includes state[:detail], "UTC+8"
    assert_equal "Off-peak", PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 20, 0))[:label]
  end

  def test_presenter_marks_model_rows_and_provider_peak
    now = Time.utc(2026, 9, 28, 7, 0)
    models = {
      "deepseek-v4-pro" => { modelId: "deepseek-v4-pro", totalTokens: 100, records: 1 },
      "glm-5.3" => { modelId: "glm-5.3", totalTokens: 50, records: 1 }
    }

    rows = TokenMaxx::Runtime::Presenter.model_usage_rows("opencode", models, now)

    assert_equal "peak", rows.find { |row| row[:modelId] == "deepseek-v4-pro" }[:peak][:state]
    assert_nil rows.find { |row| row[:modelId] == "glm-5.3" }[:peak]
  end

  def test_model_gated_provider_peak_state_comes_from_hermes_sourced_models
    # Monday 07:00 UTC sits inside the OpenCode Go DeepSeek peak window. The
    # OpenCode Go quota payload names no models, so the provider's peak state is
    # resolved from the local usage model list — which is exactly where Hermes
    # usage now lands. A meter fed only by Hermes must keep reporting peak state.
    now = Time.utc(2026, 9, 28, 7, 0)
    local_usage = {
      sources: %w[opencode-db hermes],
      models: {
        "deepseek-v4.1-flash" => { modelId: "deepseek-v4.1-flash", records: 4, totalTokens: 4_155 }
      }
    }

    assert_nil TokenMaxx::Runtime::Presenter.provider_peak("opencode", {}, [], nil, now)

    state = TokenMaxx::Runtime::Presenter.provider_peak("opencode", {}, [], local_usage, now)

    assert_equal "peak", state[:state]
    assert_equal ["deepseek-v4.1-flash"], state[:models]
  end

  def test_window_text_is_rendered_in_the_local_zone
    with_zone("America/Los_Angeles") do
      state = PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 7, 0))

      # Mon 06:00-10:00Z is Sun 23:00 - Mon 03:00 in Los Angeles.
      assert_equal "Sun 23:00\u2013Mon 03:00", state[:windowText]
    end

    with_zone("Asia/Kolkata") do
      state = PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 7, 0))

      assert_equal "Mon 11:30\u201315:30", state[:windowText]
    end
  end

  def test_window_text_applies_dst_for_the_window_instant
    with_zone("Europe/Rome") do
      winter = PEAK.model_state("zai", nil, Time.utc(2026, 1, 15, 7, 0))
      summer = PEAK.model_state("zai", nil, Time.utc(2026, 7, 15, 7, 0))

      # Same UTC window, but CET (+1) in January and CEST (+2) in July.
      assert_equal "Thu 07:00\u201311:00", winter[:windowText]
      assert_equal "Wed 08:00\u201312:00", summer[:windowText]
    end
  end

  def test_state_is_identical_across_local_zones
    instant = Time.utc(2026, 9, 28, 7, 0)
    states = %w[UTC America/Los_Angeles Asia/Kolkata Pacific/Auckland].map do |zone|
      with_zone(zone) { PEAK.model_state("zai", nil, instant)[:state] }
    end

    assert_equal ["peak"], states.uniq
  end

  def test_schedule_timeline_resolves_boundaries_exactly
    now = Time.utc(2026, 9, 28, 7, 0)
    timeline = PEAK.schedule_timeline("zai", now)

    assert_equal 0, resolve(timeline, Time.utc(2026, 9, 28, 5, 59))
    assert_equal 1, resolve(timeline, Time.utc(2026, 9, 28, 6, 0))
    assert_equal 1, resolve(timeline, Time.utc(2026, 9, 28, 9, 59))
    assert_equal 0, resolve(timeline, Time.utc(2026, 9, 28, 10, 0))
    assert_equal 0, resolve(timeline, Time.utc(2026, 10, 3, 7, 0))
  end

  def test_schedule_timeline_is_ordered_and_brackets_now
    now = Time.utc(2026, 9, 28, 7, 0)
    transitions = PEAK.schedule_timeline("zai", now)[:transitions]

    assert transitions.each_cons(2).all? { |(a, _), (b, _)| a < b }
    assert transitions.first[0] < now.to_i
    assert transitions.last[0] > now.to_i + (7 * 86_400)
  end

  def test_schedule_timeline_unknown_id_is_nil
    assert_nil PEAK.schedule_timeline("nonexistent")
  end

  def test_presenter_peak_card_includes_local_window
    state = PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 7, 0))

    with_zone("Europe/Rome") do
      card = TokenMaxx::Runtime::Presenter.peak_card(state)

      assert_equal "Rate period", card[:label]
      assert_equal "Peak", card[:value]
      assert_includes card[:detail], "local"
      assert_includes card[:detail], "\u2013"
    end
  end

  def test_presenter_view_exposes_compiled_schedules
    view = TokenMaxx::Runtime::Presenter.build_snapshot_view(build_config, { results: {}, overviewProviders: [] }, Time.utc(2026, 9, 28, 7, 0))
    schedules = view[:peakSchedules]

    assert schedules.key?("zai")
    assert schedules.key?("ollama:deepseek")
    assert schedules.key?("opencode:deepseek")
    assert schedules["zai"][:transitions].length.positive?
  end

  def test_static_peak_fields_describe_the_same_period_as_the_compiled_timeline
    # Two paths render one badge. The panel resolves the compiled timeline
    # against its own clock, and every snapshot-only consumer (the Waybar
    # tooltip, the Peak card, and the panel's version-skew fallback) renders the
    # static fields instead. They must name the same period, or the same state
    # reads differently depending on which path drew it. Off-peak is where the
    # static fields used to drift: the badge said "Off-peak" next to the hours
    # of the upcoming peak window.
    monday = Time.utc(2026, 9, 28, 0, 0)
    instants = (0...(7 * 48)).map { |step| monday + (step * 1800) }

    with_zone("Europe/Rome") do
      PEAK::SCHEDULES.each do |schedule|
        timeline = PEAK.schedule_timeline(schedule[:id], monday)
        model_id = schedule[:model] ? "deepseek-v4-pro" : nil

        instants.each do |now|
          state = PEAK.state_for(schedule, model_id, now)
          (start_at, finish_at), expected_state = current_period(timeline, now)

          assert_equal expected_state, state[:state], "state at #{now} for #{schedule[:id]}"
          assert_equal start_at, state[:windowStartAt], "window start at #{now} for #{schedule[:id]}"
          assert_equal finish_at, state[:windowEndAt], "window end at #{now} for #{schedule[:id]}"
          assert_equal PEAK.local_span(Time.at(start_at), Time.at(finish_at)), state[:windowText],
                       "window text at #{now} for #{schedule[:id]}"
        end
      end
    end
  end

  def test_off_peak_window_is_the_off_peak_span_not_the_next_peak_span
    # Monday 10:00 UTC is the first off-peak minute for Z.ai (the peak window is
    # 06:00-10:00 UTC). Its rate period runs to the next peak start on Tuesday.
    state = PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 10, 0))

    assert_equal "offpeak", state[:state]
    assert_equal Time.utc(2026, 9, 28, 10, 0).to_i, state[:windowStartAt]
    assert_equal Time.utc(2026, 9, 29, 6, 0).to_i, state[:windowEndAt]

    with_zone("UTC") do
      assert_equal "Mon 10:00\u2013Tue 06:00", PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 10, 0))[:windowText]
    end
  end

  def test_weekend_off_peak_period_spans_from_friday_close_to_monday_open
    # Friday 10:00 UTC closes Z.ai's last weekday peak; the next one opens
    # Monday 06:00 UTC, so the off-peak rate period covers the whole weekend.
    state = PEAK.model_state("zai", nil, Time.utc(2026, 10, 3, 12, 0))

    assert_equal "offpeak", state[:state]
    assert_equal Time.utc(2026, 10, 2, 10, 0).to_i, state[:windowStartAt]
    assert_equal Time.utc(2026, 10, 5, 6, 0).to_i, state[:windowEndAt]
  end

  def test_peak_window_is_unchanged_while_peak_is_active
    state = PEAK.model_state("zai", nil, Time.utc(2026, 9, 28, 7, 0))

    assert_equal "peak", state[:state]
    assert_equal Time.utc(2026, 9, 28, 6, 0).to_i, state[:windowStartAt]
    assert_equal Time.utc(2026, 9, 28, 10, 0).to_i, state[:windowEndAt]
  end

  private

  # The panel's own resolution, mirrored: the last transition at or before now
  # is the current state, and the next transition ends the current period.
  def current_period(timeline, now)
    transitions = timeline[:transitions]
    state = transitions.first[1]
    start_at = transitions.first[0]
    finish_at = transitions.last[0]

    transitions.each do |at, value|
      if at <= now.to_i
        state = value
        start_at = at
      else
        finish_at = at
        break
      end
    end

    [[start_at, finish_at], state.to_i.zero? ? "offpeak" : "peak"]
  end

  def resolve(timeline, time)
    state = timeline[:transitions].first[1]
    timeline[:transitions].each { |(at, value)| state = value if at <= time.to_i }
    state
  end

  def with_zone(zone)
    previous = ENV["TZ"]
    ENV["TZ"] = zone
    yield
  ensure
    previous.nil? ? ENV.delete("TZ") : ENV["TZ"] = previous
  end
end
