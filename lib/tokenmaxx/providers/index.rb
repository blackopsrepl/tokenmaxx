# frozen_string_literal: true

module TokenMaxx
  module Providers
    FETCHERS = {
      "codex" => ->(config) { Providers::Codex.fetch(config) },
      "claude" => ->(config) { Providers::Claude.fetch(config) },
      "gemini" => ->(config) { Providers::Gemini.fetch(config) },
      "opencode" => ->(config) { Providers::Opencode.fetch(config) },
      "zai" => ->(config) { Providers::Zai.fetch(config) },
      "ollama" => ->(config) { Providers::Ollama.fetch(config) }
    }.freeze

    module_function

    def fetch_provider(config, provider)
      provider_config = Core::Types.provider_config_for(config, provider)
      fetcher = FETCHERS[provider]
      unless fetcher
        return {
          provider: provider,
          source: provider_config[:source] || "auto",
          notes: [],
          error: "Provider #{provider} is not implemented yet in the rewrite."
        }
      end

      fetcher.call(provider_config.merge(stateDir: config.dig(:runtime, :stateDir)))
    end

    def fetch_providers(config, providers)
      providers.each_with_object({}) do |provider, results|
        results[provider] = fetch_provider(config, provider)
      end
    end
  end
end
