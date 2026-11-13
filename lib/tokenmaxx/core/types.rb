# frozen_string_literal: true

module TokenMaxx
  module Core
    module Types
      ALL_PROVIDERS = %w[
        codex
        claude
        gemini
        opencode
        zai
        ollama
      ].freeze

      PROVIDER_METADATA = {
        "codex" => { label: "Codex", shortLabel: "CX", sessionLabel: "5-hour", weeklyLabel: "Weekly", defaultEnabled: false, supportsAverage: false, supportsTertiary: false, accent: "#82FB9C", icon: "󰚩", dashboardUrl: "https://chatgpt.com/codex" },
        "claude" => { label: "Claude", shortLabel: "CL", sessionLabel: "Session", weeklyLabel: "Weekly", tertiaryLabel: "Sonnet", defaultEnabled: false, supportsAverage: false, supportsTertiary: true, accent: "#F2C572", icon: "", dashboardUrl: "https://claude.ai/" },
        "gemini" => { label: "Gemini", shortLabel: "GM", sessionLabel: "Pro", weeklyLabel: "Flash", defaultEnabled: false, supportsAverage: true, supportsTertiary: false, accent: "#82A7F4", icon: "", dashboardUrl: "https://gemini.google.com/" },
        "opencode" => { label: "OpenCode Go", shortLabel: "OC", sessionLabel: "5-hour", weeklyLabel: "Weekly", tertiaryLabel: "Monthly", defaultEnabled: false, supportsAverage: false, supportsTertiary: true, accent: "#C792EA", icon: "", dashboardUrl: "https://opencode.ai/" },
        "zai" => { label: "Z.ai", shortLabel: "Z", sessionLabel: "5-hour", weeklyLabel: "Weekly", tertiaryLabel: "Tools", defaultEnabled: false, supportsAverage: false, supportsTertiary: true, accent: "#4ECDC4", icon: "󰉁", dashboardUrl: "https://z.ai/manage-apikey/coding-plan/personal/my-plan" },
        "ollama" => { label: "Ollama Cloud", shortLabel: "OL", sessionLabel: "Monthly", weeklyLabel: "Weekly", defaultEnabled: false, supportsAverage: false, supportsTertiary: false, accent: "#8AB4F8", icon: "", dashboardUrl: "https://ollama.com/settings" },
      }.freeze

      STATUS_METADATA = {
        "codex" => {
          source: "openai-status",
          url: "https://status.openai.com/api/v2/components.json",
          enrichmentUrl: "https://status.openai.com/proxy/openai-1",
          fallbackUrl: "https://status.openai.com/api/v2/summary.json",
          pageId: "01JMDK9XYNY6RXSED6SDWW50WY",
          sourceUrl: "https://status.openai.com/",
          services: [
            { id: "01KMP3KP5MGE23B80K1EK4S8PV", name: "Codex API", aliases: ["Codex API"] },
            { id: "01KMKFAMWKNQ84Z1766MV08ZDE", name: "Codex CLI", aliases: ["CLI", "Codex CLI"] }
          ]
        },
        "claude" => {
          source: "claude-status",
          url: "https://status.claude.com/api/v2/summary.json",
          sourceUrl: "https://status.claude.com/",
          pageId: "tymt9n04zgry",
          services: [
            { id: "yyzkbfz2thpt", name: "Claude Code", aliases: ["Claude Code"] },
            { id: "k8w3r06qmzrp", name: "Claude API", aliases: ["Claude API", "api.anthropic.com", "Claude API (api.anthropic.com)"] }
          ]
        },
        "gemini" => {
          source: "google-cloud-status",
          url: "https://status.cloud.google.com/incidents.json",
          sourceUrl: "https://status.cloud.google.com/",
          products: ["Vertex Gemini API", "Gemini Code Assist"]
        },
        "opencode" => {
          source: "opencode-go-usage",
          url: nil,
          sourceUrl: "https://opencode.ai/",
          components: []
        },
        "zai" => {
          source: "zai-quota",
          url: nil,
          sourceUrl: "https://z.ai/",
          components: []
},
"ollama" => {
  source: "ollama-cloud-balance",
  url: nil,
  sourceUrl: "https://ollama.com/",
  components: []
}
      }.freeze

      module_function

      def usage_provider?(value)
        ALL_PROVIDERS.include?(value)
      end

      def provider_config_for(config, provider)
        found = config[:providers].find { |entry| entry[:id] == provider }
        found || { id: provider, enabled: PROVIDER_METADATA.fetch(provider)[:defaultEnabled] }
      end

      def rate_window_remaining_percent(window)
        return nil unless window

        [0, 100 - window[:usedPercent].to_f].max
      end
    end
  end
end
