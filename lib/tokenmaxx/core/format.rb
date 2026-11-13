# frozen_string_literal: true

require "time"

module TokenMaxx
  module Core
    module Format
      module_function

      def usage_line(window, show_used)
        value = show_used ? window[:usedPercent].to_f : (Types.rate_window_remaining_percent(window) || 0)
        "#{clamp(value, 0, 100).round}% #{show_used ? 'used' : 'left'}"
      end

      def reset_countdown_description(time, now = Time.now)
        seconds = [0, (time - now).ceil].max
        return "now" if seconds < 1

        total_minutes = [1, (seconds / 60.0).ceil].max
        days = total_minutes / (24 * 60)
        hours = (total_minutes / 60) % 24
        minutes = total_minutes % 60

        return hours.positive? ? "in #{days}d #{hours}h" : "in #{days}d" if days.positive?
        return minutes.positive? ? "in #{hours}h #{minutes}m" : "in #{hours}h" if hours.positive?

        "in #{total_minutes}m"
      end

      def reset_description(time, now = Time.now)
        return format_clock(time) if same_day?(time, now)

        tomorrow = now + (24 * 60 * 60)
        return "tomorrow, #{format_clock(time)}" if same_day?(time, tomorrow)

        time.strftime("%b %-d %-l:%M %p").strip
      end

      def reset_line(window, style, now = Time.now)
        if window[:resetsAt]
          time = Time.parse(window[:resetsAt])
          label = style == "countdown" ? reset_countdown_description(time, now) : reset_description(time, now)
          return "Resets #{label}"
        end

        description = clean(window[:resetDescription])
        return nil unless description

        description.downcase.start_with?("resets") ? description : "Resets #{description}"
      end

      def credits_string(credits)
        "#{format('%.2f', credits[:remaining].to_f).sub(/\.00$/, '')} left"
      end

      def spend_summary_line(label, summary)
        return nil unless summary

        parts = []
        parts << "$#{money_string(summary[:cost].to_f)}"
        parts << "#{summary[:requests].to_i} req"
        parts << "#{summary[:tokens].to_i} tok" if summary[:tokens].to_i.positive?
        [label, parts.join(" · ")].join(": ")
      end

      def token_summary_line(summary)
        return nil unless summary

        tokens = summary[:totalTokens].to_i
        parts = []
        parts << "#{compact_count(tokens)} tok" if tokens.positive?
        parts << "#{summary[:records].to_i} records" if summary[:records].to_i.positive?
        parts << "$#{money_string(summary[:cost].to_f)}" if summary[:cost]
        parts.empty? ? nil : parts.join(" · ")
      end

      def bytes_string(value)
        amount = value.to_f
        units = %w[B KB MB GB TB]
        index = 0
        while amount >= 1024 && index < units.length - 1
          amount /= 1024.0
          index += 1
        end

        return "#{amount.to_i} #{units[index]}" if index.zero?

        "#{format('%.1f', amount).sub('.0', '')} #{units[index]}"
      end

      def escape_markup(value)
        value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&apos;")
      end

      # The caller must first apply Status.for_display, including expiration.
      # Coding health in a few words: the state, plus the coding services it names.
      def service_status_text(status)
        label = service_state_text(status)
        return label unless ["Degraded", "Partial outage", "Maintenance", "Outage"].include?(label)

        affected = affected_service_names(status)
        affected.empty? ? label : "#{label}: #{affected.join(', ')}"
      end

      # The colour follows the shared alert scale (Runtime::Status); the label
      # keeps the vendor's wording inside the degraded tier.
      def service_state_text(status)
        return "Status unknown" unless status && !status.empty?
        return "No status page" if status[:statusPage] == false
        return "Status stale" if status[:freshness] == "stale"

        state = status[:state].to_s
        if state == "degraded"
          raw = Array(status[:services]).select { |service| service[:state].to_s == "degraded" }.map { |service| service[:rawStatus].to_s }
          return "Partial outage" if raw.include?("partial_outage")
          return "Maintenance" if !raw.empty? && raw.all?("under_maintenance")
        end
        # "Operational" beside a degraded connector reads as all-clear; scope it.
        return other_services_state(status) ? "Coding operational" : "Operational" if state == "ok"

        { "degraded" => "Degraded", "outage" => "Outage" }.fetch(state, "Status unknown")
      end

      def affected_service_names(status)
        Array(status && status[:services]).select { |service| %w[degraded outage].include?(service[:state].to_s) }
                                          .filter_map { |service| clean(service[:name]) }
      end

      # Active incidents scoped to non-coding services (connectors, web apps). They
      # stay apart from coding health so they never read as a coding outage.
      def other_service_incidents(status)
        Array(status && status[:incidents]).select do |incident|
          %w[other unconfirmed].include?(incident[:scope].to_s) && %w[degraded outage].include?(incident[:state].to_s)
        end
      end

      def other_services_state(status)
        states = other_service_incidents(status).map { |incident| incident[:state].to_s }
        return "outage" if states.include?("outage")

        states.empty? ? nil : "degraded"
      end

      # The non-coding services those incidents name, so the notice says what is
      # affected (for example `Connectors/Apps degraded`) instead of a generic label.
      def other_service_names(status)
        coding = Array(status && status[:services]).filter_map { |service| clean(service[:name])&.downcase }
        other_service_incidents(status).flat_map { |incident| Array(incident[:affectedServices]) }
                                       .filter_map { |entry| clean(entry.is_a?(Hash) ? entry[:name] : entry) }
                                       .reject { |name| coding.include?(name.downcase) }.uniq
      end

      # One shared upstream cause (a Microsoft 365 connector failure hitting both
      # OpenAI and Anthropic) must read the same on every card, but each vendor
      # files it under different components. The incident title names the actual
      # subject ("Elevated errors affecting the Microsoft 365 connector"), so it
      # wins; component names are the fallback when the title names none.
      SUBJECT_PATTERN = /\b(?:affecting|impacting)\s+(?:the\s+)?(?<subject>.+?)\s*\z/i

      def other_services_text(status)
        state = other_services_state(status)
        return nil unless state

        incidents = other_service_incidents(status)
        subjects = incidents.map { |incident| clean(incident[:title])&.match(SUBJECT_PATTERN)&.[](:subject) }
        names = subjects.all? ? subjects.uniq : other_service_names(status)
        names = incidents.filter_map { |incident| clean(incident[:title]) }.uniq if names.empty?
        names.empty? ? "Other services #{state}" : "#{names.join(', ')} #{state}"
      end

      def redact_email(value)
        text = clean(value)
        return nil unless text

        local, domain = text.split("@", 2)
        return "hidden" unless local && domain

        "#{local[0]}***@#{domain}"
      end

      def date_label(value)
        time = Time.parse(value.to_s)
        time.strftime("%b %-d")
      rescue ArgumentError
        value.to_s
      end

      def spend_compact_text(spend)
        month = spend[:month]
        return nil unless month

        if month[:cost].to_f.positive?
          "$#{money_string(month[:cost].to_f)} mo"
        elsif month[:tokens].to_i.positive?
          "#{compact_count(month[:tokens].to_i)} tok"
        else
          "#{month[:requests].to_i} req mo"
        end
      end

      def money_string(amount)
        rounded = amount.to_f
        return format("%.2f", rounded) if rounded.zero? || rounded.abs >= 1

        format("%.4f", rounded).sub(/0+$/, "").sub(/\.$/, "")
      end

      def compact_count(value)
        amount = value.to_i
        return amount.to_s if amount < 1000
        return format("%.1fk", amount / 1000.0).sub(".0k", "k") if amount < 1_000_000

        format("%.1fM", amount / 1_000_000.0).sub(".0M", "M")
      end

      def window_label(window, fallback)
        text = window[:label].to_s.strip
        text.empty? ? fallback : text
      end

      def render_provider_text(provider, snapshot, credits, show_used, reset_style)
        metadata = Types::PROVIDER_METADATA.fetch(provider)
        lines = []
        meters = Array(snapshot[:meters])
        primary = snapshot[:primary]
        secondary = snapshot[:secondary]
        tertiary = snapshot[:tertiary]

        lines << "#{metadata[:label]} (#{snapshot.dig(:identity, :loginMethod) || 'active'})"

        if meters.any?
          meters.each do |meter|
            lines << "#{meter[:label]}: #{usage_line(meter, show_used)}"
            reset = reset_line(meter, reset_style)
            lines << reset if reset
          end
        elsif primary
          lines << "#{window_label(primary, metadata[:sessionLabel])}: #{usage_line(primary, show_used)}"
          reset = reset_line(primary, reset_style)
          lines << reset if reset
        end

        if secondary
          lines << "#{window_label(secondary, metadata[:weeklyLabel])}: #{usage_line(secondary, show_used)}"
          reset = reset_line(secondary, reset_style)
          lines << reset if reset
          pace = Metric.pace_summary_text(secondary)
          lines << "Pace: #{pace}" if pace
        end

        if tertiary
          lines << "#{window_label(tertiary, metadata[:tertiaryLabel] || 'Tertiary')}: #{usage_line(tertiary, show_used)}"
          reset = reset_line(tertiary, reset_style)
          lines << reset if reset
        end

        lines << "Credits: #{credits_string(credits)}" if credits
        lines << "Account: #{snapshot.dig(:identity, :accountEmail)}" if snapshot.dig(:identity, :accountEmail)

        if snapshot[:providerCost]
          lines << format(
            "Cost: %.2f / %.2f %s",
            snapshot[:providerCost][:used].to_f,
            snapshot[:providerCost][:limit].to_f,
            snapshot[:providerCost][:currencyCode]
          )
        end

        if snapshot[:spend]
          lines << spend_summary_line("Today", snapshot[:spend][:today])
          lines << spend_summary_line("7d", snapshot[:spend][:sevenDay])
          lines << spend_summary_line("Month", snapshot[:spend][:month])
        end

        lines.join("\n")
      end

      def compact_status_text(provider, snapshot, show_used, display_mode, preference)
        return "#{Types::PROVIDER_METADATA.fetch(provider)[:shortLabel]} --" unless snapshot

        compact = Metric.compact_display_text(display_mode, preference, show_used)
        compact ||= spend_compact_text(snapshot[:spend])
        compact = "#{preference.dig(:window, :shortLabel)} #{compact}" if compact && snapshot[:meters] && preference.dig(:window, :shortLabel)
        compact ? "#{Types::PROVIDER_METADATA.fetch(provider)[:shortLabel]} #{compact}" : "#{Types::PROVIDER_METADATA.fetch(provider)[:shortLabel]} --"
      end

      def progress_bar(percent_used, width = 20)
        percent = clamp(percent_used.to_f, 0, 100)
        filled = ((percent / 100.0) * width).round
        empty = [0, width - filled].max
        "[#{('#' * filled)}#{('-' * empty)}]"
      end

      def window_severity(window)
        remaining = Types.rate_window_remaining_percent(window)
        return nil unless remaining
        return "critical" if remaining <= 10
        return "warning" if remaining <= 25

        "healthy"
      end

      def compact_reset_text(window, style = "countdown", now = Time.now)
        return nil unless window

        if window[:resetsAt]
          time = Time.parse(window[:resetsAt])
          return style == "countdown" ? reset_countdown_description(time, now) : reset_description(time, now)
        end

        clean(window[:resetDescription])
      end

      def color_for_window(window)
        remaining = Types.rate_window_remaining_percent(window)
        return nil unless remaining
        return "#ff6b6b" if remaining <= 10
        return "#ffb454" if remaining <= 25
        return "#f4d35e" if remaining <= 50

        "#9be564"
      end

      def updated_string(timestamp)
        time = Time.parse(timestamp)
        seconds = [0, (Time.now - time).round].max
        return "Updated just now" if seconds < 60
        return "Updated #{[1, seconds / 60].max}m ago" if seconds < 3600
        return "Updated #{[1, seconds / 3600].max}h ago" if seconds < 86_400

        "Updated #{format_clock(time)}"
      end

      def clean(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def same_day?(left, right)
        left.year == right.year && left.yday == right.yday
      end

      def format_clock(time)
        time.strftime("%-l:%M %p").strip
      end

      def clamp(value, min, max)
        [[value, min].max, max].min
      end
    end
  end
end
