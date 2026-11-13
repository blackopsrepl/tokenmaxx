# frozen_string_literal: true

require "time"

module TokenMaxx
  module Core
    # Peak versus off-peak rate windows for providers that bill by time of day.
    #
    # The windows are vendor-documented and fixed in UTC; none of the supported
    # provider APIs expose them at runtime (the Ollama usage endpoint returns
    # only fraction windows and the Z.ai quota endpoint only `limits[]`), so they
    # are declared here. Only the standing recurring schedules are encoded:
    # limited-time vendor promotions are intentionally not tracked, because a
    # hardcoded promotion would keep reporting a discount after it expires. When
    # a provider changes a schedule this table must be updated; see
    # docs/providers.md.
    #
    # Everything this module emits is timezone-absolute. Windows are anchored to
    # UTC calendar days, state is evaluated against UTC, and each schedule is
    # serialized as an alternating transition timeline of Unix epochs. A consumer
    # therefore resolves the current state and formats the current/next window in
    # its own local zone, with DST applied from the zone database, without
    # reimplementing the schedule and without knowing the machine's zone.
    module Peak
      WEEKDAYS = (1..5).freeze
      OFF_PEAK = "offpeak"
      PEAK = "peak"
      # Days of context emitted on each side of "now" so every consumer always
      # has a transition at or before the current instant plus a full recurring
      # week ahead.
      TIMELINE_DAYS = 8

      # Each schedule lists peak windows as [weekday_range, start_minute,
      # end_minute] in UTC minutes from midnight; everything outside the windows
      # is off-peak. A model pattern restricts a schedule to matching model ids;
      # nil applies it to every model the provider serves.
      SCHEDULES = [
        {
          id: "zai",
          provider: "zai",
          model: nil,
          peak: [[WEEKDAYS, 360, 600]],
          detail: "GLM Coding Plan peaks Mon-Fri 14:00-18:00 (UTC+8); off-peak usage is charged at 50% credits."
        },
        {
          id: "ollama:deepseek",
          provider: "ollama",
          model: /\Adeepseek-(?:v4\.1-flash|v4-pro)(?::(?:\d+-)?cloud)?\z/,
          peak: [[WEEKDAYS, 720, 1080]],
          detail: "Ollama Cloud DeepSeek V4.1 Flash and V4 Pro off-peak pricing applies outside Mon-Fri 12:00-18:00 UTC."
        },
        {
          id: "opencode:deepseek",
          provider: "opencode",
          model: /\Adeepseek-(?:v4\.1-flash|v4-pro)\z/,
          peak: [[WEEKDAYS, 60, 240], [WEEKDAYS, 360, 600]],
          detail: "DeepSeek V4.1 Flash and V4 Pro peak Mon-Fri 01:00-04:00 and 06:00-10:00 UTC; all other hours are off-peak."
        }
      ].freeze

      module_function

      def schedule_by_id(schedule_id)
        SCHEDULES.find { |schedule| schedule[:id] == schedule_id.to_s }
      end

      def schedule_for(provider, model_id = nil)
        SCHEDULES.find do |schedule|
          next false unless schedule[:provider] == provider.to_s
          next true if schedule[:model].nil?

          schedule[:model].match?(model_id.to_s)
        end
      end

      def model_state(provider, model_id, now = Time.now.utc)
        schedule = schedule_for(provider, model_id)
        return nil unless schedule

        state_for(schedule, model_id, now)
      end

      # Aggregate for a provider's known model ids. Every matching model shares
      # one schedule, so the result is uniform; nil means no model has a
      # time-of-day schedule (including a model-gated provider with no matching
      # model).
      def provider_state(provider, model_ids, now = Time.now.utc)
        ids = Array(model_ids).map(&:to_s).reject(&:empty?)
        schedule = schedule_for(provider)
        matching = if schedule&.dig(:model).nil? && !schedule.nil?
                     ids.empty? ? [nil] : ids
                   else
                     ids.select { |id| schedule_for(provider, id) }
                   end
        return nil if matching.empty?

        state = state_for(schedule_for(provider, matching.first), matching.first, now)
        return nil unless state

        state.merge(provider: provider.to_s, models: matching.reject(&:nil?))
      end

      def state_for(schedule, model_id, now)
        window = current_rate_window(schedule, now)
        return nil unless window

        active = peak_now?(schedule, now)
        start_time, end_time = window
        {
          scheduleId: schedule[:id],
          modelId: model_id.to_s,
          state: active ? PEAK : OFF_PEAK,
          label: active ? "Peak" : "Off-peak",
          detail: schedule[:detail],
          windowStartAt: start_time.to_i,
          windowEndAt: end_time.to_i,
          windowText: local_span(start_time, end_time)
        }
      end

      # Serialized schedule for consumers that resolve state against their own
      # clock: the vendor detail plus an ordered `[epoch, 1|0]` transition list
      # (1 = peak). The first entry is the state in effect before the first
      # transition, so a simple scan yields the correct state at any instant.
      def schedule_timeline(schedule_id, now = Time.now.utc)
        schedule = schedule_by_id(schedule_id)
        return nil unless schedule

        events = []
        intervals(schedule, now).each do |start, finish|
          events << [start.to_i, 1]
          events << [finish.to_i, 0]
        end
        return { detail: schedule[:detail], transitions: [] } if events.empty?

        anchor = events.first[0] - 1
        timeline = [[anchor, 0]] + events
        { detail: schedule[:detail], transitions: timeline.sort_by(&:first).uniq { |at, _state| at } }
      end

      def peak_now?(schedule, now)
        utc = now.utc
        minutes = (utc.hour * 60) + utc.min
        wday = utc.wday
        schedule[:peak].any? do |days, start_minute, end_minute|
          days.cover?(wday) && minutes >= start_minute && minutes < end_minute
        end
      end

      # Concrete peak intervals across a window around now, as [start, end] UTC
      # Times. Anchored to UTC calendar days so the result is independent of the
      # evaluating machine's zone.
      def intervals(schedule, now, days: TIMELINE_DAYS)
        base = now.utc.to_date
        ((base - days)..(base + days)).flat_map do |date|
          schedule[:peak].filter_map do |dows, start_minute, end_minute|
            next unless dows.cover?(date.wday)

            [time_at(date, start_minute), time_at(date, end_minute)]
          end
        end.sort_by(&:first)
      end

      def time_at(date, minute_of_day)
        Time.utc(date.year, date.month, date.day, minute_of_day / 60, minute_of_day % 60)
      end

      # The window of the rate period in effect at `now`: the peak interval
      # containing `now`, or, while off-peak, the gap between the surrounding
      # peak intervals (which runs from one weekday close to the next open, so a
      # weekend off-peak period spans two dates). Consumers that cannot resolve a
      # compiled timeline — the Waybar tooltip, the Peak detail card, and the
      # panel's snapshot fallback — render these static fields as the current
      # window, so they must describe the same period the timeline resolves.
      def current_rate_window(schedule, now)
        windows = intervals(schedule, now)
        peak_window = windows.find { |start, finish| start <= now && now < finish }
        return peak_window if peak_window

        previous_end = windows.filter_map { |_start, finish| finish if finish <= now }.max
        next_start = windows.filter_map { |start, _finish| start if start > now }.min
        return nil unless previous_end && next_start

        [previous_end, next_start]
      end

      # Renders a peak window in the evaluating machine's local zone, correct at
      # the window's own instant (so DST is applied from the zone database, not
      # from a fixed offset).
      def local_span(start_time, finish_time)
        start_local = start_time.getlocal
        finish_local = finish_time.getlocal
        if start_local.to_date == finish_local.to_date
          "#{start_local.strftime('%a %H:%M')}\u2013#{finish_local.strftime('%H:%M')}"
        else
          "#{start_local.strftime('%a %H:%M')}\u2013#{finish_local.strftime('%a %H:%M')}"
        end
      end
    end
  end
end
