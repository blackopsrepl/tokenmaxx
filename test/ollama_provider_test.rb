# frozen_string_literal: true

require_relative "test_helper"

class OllamaProviderTest < Minitest::Test
  def test_monthly_balance_maps_to_the_primary_lane
    payload = {
      included: {
        balance_usd: 87.5,
        allowance_usd: 100,
        period: { from: "2026-09-27T14:15:45Z", until: "2026-10-27T14:15:45Z" }
      },
      purchased: { balance_usd: 0 }
    }

    result = fetch_with(payload)

    assert_nil result[:error]
    assert_equal "ollama", result[:provider]
    assert_equal "ollama-cloud", result[:source]

    usage = result[:usage]
    assert_equal 12.5, usage.dig(:primary, :usedPercent)
    assert_equal "Monthly", usage.dig(:primary, :label)
    assert_equal "mo", usage.dig(:primary, :shortLabel)
    assert_equal 43_200, usage.dig(:primary, :windowMinutes)
    assert_equal "2026-10-27T14:15:45Z", usage.dig(:primary, :resetsAt)
    assert_nil usage[:secondary]
    assert_equal "Ollama Cloud", usage.dig(:identity, :loginMethod)
    assert_empty result[:notes]
  end

  def test_monthly_allowance_is_clamped_to_0_100
    low = fetch_with(included: { balance_usd: -5, allowance_usd: 100 })
    assert_equal 100.0, low[:usage].dig(:primary, :usedPercent)

    high = fetch_with(included: { balance_usd: 110, allowance_usd: 100 })
    assert_equal 0.0, high[:usage].dig(:primary, :usedPercent)
  end

  def test_monthly_period_sets_the_window_length_and_reset_time
    payload = {
      included: {
        balance_usd: 50,
        allowance_usd: 100,
        period: { from: "2026-10-01T00:00:00Z", until: "2026-10-29T00:00:00Z" }
      }
    }

    result = fetch_with(payload)

    assert_equal 40_320, result[:usage].dig(:primary, :windowMinutes)
    assert_equal "2026-10-29T00:00:00Z", result[:usage].dig(:primary, :resetsAt)
  end

  def test_purchased_credits_add_a_note_without_changing_the_lane
    payload = {
      included: { balance_usd: 87.5, allowance_usd: 100 },
      purchased: { balance_usd: 25 }
    }

    result = fetch_with(payload)

    assert_nil result[:error]
    assert_equal ["Includes $25.00 of purchased credits."], result[:notes]
    assert_equal 12.5, result[:usage].dig(:primary, :usedPercent)
  end

  def test_legacy_session_and_weekly_plan_maps_to_primary_and_secondary
    payload = {
      included: {
        session: { remaining_percent: 98.0, resets_at: "2026-10-09T20:00:00Z" },
        weekly: { remaining_percent: 66.5, resets_at: "2026-10-12T00:00:00Z" }
      }
    }

    result = fetch_with(payload)

    assert_nil result[:error]
    usage = result[:usage]
    assert_equal 2.0, usage.dig(:primary, :usedPercent)
    assert_equal 300, usage.dig(:primary, :windowMinutes)
    assert_equal "5h", usage.dig(:primary, :shortLabel)
    assert_equal "2026-10-09T20:00:00Z", usage.dig(:primary, :resetsAt)
    assert_equal 33.5, usage.dig(:secondary, :usedPercent)
    assert_equal 10_080, usage.dig(:secondary, :windowMinutes)
    assert_equal "W", usage.dig(:secondary, :shortLabel)
    assert_equal "2026-10-12T00:00:00Z", usage.dig(:secondary, :resetsAt)
  end

  def test_missing_allowance_returns_error
    result = fetch_with(included: {})

    assert_match(/did not include a usable allowance/, result[:error])
    assert_nil result[:usage]
  end

  def test_resolve_api_key_prefers_env_then_opencode_auth
    with_env("OLLAMA_API_KEY" => "sk-env") do
      with_temp_auth(key: "sk-auth") do
        assert_equal "sk-env", TokenMaxx::Providers::Ollama.resolve_api_key
      end
    end

    with_env("OLLAMA_API_KEY" => nil) do
      with_temp_auth(key: "sk-auth") do
        assert_equal "sk-auth", TokenMaxx::Providers::Ollama.resolve_api_key
      end
    end
  end

  def test_missing_key_returns_error
    with_env("OLLAMA_API_KEY" => nil) do
      Dir.mktmpdir("tokenmaxx-ollama") do |dir|
        path = File.join(dir, "auth.json")
        File.write(path, JSON.generate("opencode" => { type: "api", key: "sk-other" }))
        with_env("TOKENMAXX_OPENCODE_AUTH" => path) do
          result = TokenMaxx::Providers::Ollama.fetch({})

          assert_match(/API key not found/, result[:error])
          assert_nil result[:usage]
        end
      end
    end
  end

  def test_http_error_returns_error
    response = TokenMaxx::Core::Http::Response.new(status: 401, body: "", headers: {})

    result = nil
    with_temp_auth(key: "sk-auth") do
      TokenMaxx::Core::Http.stub(:request, response) do
        result = TokenMaxx::Providers::Ollama.fetch({})
      end
    end

    assert_equal "Ollama Cloud balance request failed with HTTP 401.", result[:error]
  end

  private

  def fetch_with(payload)
    response = TokenMaxx::Core::Http::Response.new(status: 200, body: JSON.generate(payload), headers: {})
    result = nil
    with_temp_auth(key: "sk-auth") do
      TokenMaxx::Core::Http.stub(:request, response) do
        result = TokenMaxx::Providers::Ollama.fetch({})
      end
    end
    result
  end

  def with_temp_auth(key:)
    Dir.mktmpdir("tokenmaxx-ollama") do |dir|
      path = File.join(dir, "auth.json")
      File.write(path, JSON.generate("ollama-cloud" => { type: "api", key: key }))
      with_env("TOKENMAXX_OPENCODE_AUTH" => path) { yield path }
    end
  end

  def with_env(values)
    previous = values.transform_values { |_| nil }
    values.each_key { |name| previous[name] = ENV[name] }
    values.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    yield
  ensure
    previous.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end
end
