# frozen_string_literal: true

require_relative "test_helper"

class ClaudeProviderTest < Minitest::Test
  def test_renewal_sends_claude_codes_request_and_keeps_its_fields
    requests = []
    responder = lambda do |_method, url, **options|
      requests << options.merge(url: url)
      if url.end_with?("/oauth/token")
        json_response(200, access_token: "new-access", refresh_token: "new-refresh", expires_in: 28_800,
                           refresh_token_expires_in: 2_592_000, scope: "user:inference user:profile")
      else
        json_response(200, five_hour: { utilization: 12, resets_at: "2026-11-18T15:00:00Z" })
      end
    end

    result, stored = with_claude_home(expires_in: -60) do
      TokenMaxx::Core::Http.stub(:request, responder) { TokenMaxx::Providers::Claude.fetch(state_config) }
    end

    assert_nil result[:error]
    assert_equal 12.0, result.dig(:usage, :primary, :usedPercent)
    token_request = requests.first
    assert_equal "https://platform.claude.com/v1/oauth/token", token_request[:url]
    assert_equal "old-refresh", token_request.dig(:json, :refresh_token)
    assert_equal "user:inference user:profile", token_request.dig(:json, :scope)
    assert_equal "Bearer new-access", requests.last.dig(:headers, "Authorization")
    oauth = stored[:claudeAiOauth]
    assert_equal "new-refresh", oauth[:refreshToken]
    assert_equal "max", oauth[:subscriptionType]
    assert_equal "default_claude_max_20x", oauth[:rateLimitTier]
    assert oauth[:refreshTokenExpiresAt] > oauth[:expiresAt]
    assert_equal({ server: { accessToken: "mcp" } }, stored[:mcpOAuth])
  end

  def test_rejected_refresh_token_asks_for_a_new_login
    responder = ->(*_args, **_options) { json_response(400, error: "invalid_grant", error_description: "Refresh token expired") }

    result, = with_claude_home(expires_in: -60) do
      TokenMaxx::Core::Http.stub(:request, responder) { TokenMaxx::Providers::Claude.fetch(state_config) }
    end

    assert_match "Claude login needs a new sign-in: the refresh token was rejected", result[:error]
    assert_match "Run `claude` and `/login`", result[:error]
    assert_nil result[:usage]
  end

  def test_renewal_takes_claude_code_and_hermes_locks
    store, = with_claude_home(expires_in: 3600) { TokenMaxx::Providers::Claude.credential_store }
    paths = store.locks.map { |lock| [lock[:kind], File.basename(lock[:path])] }

    assert_equal [[:mkdir, ".oauth_refresh.lock"], [:mkdir, ".claude.lock"], [:flock, ".credentials.lock"]], paths
    assert store.rotating
  end

  private

  def state_config
    { stateDir: File.join(ENV.fetch("HOME"), "state") }
  end

  def with_claude_home(expires_in:)
    Dir.mktmpdir("tokenmaxx-claude-home") do |home|
      previous_home = ENV["HOME"]
      ENV["HOME"] = home
      path = File.join(home, ".claude", ".credentials.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(
                         claudeAiOauth: {
                           accessToken: "old-access",
                           refreshToken: "old-refresh",
                           expiresAt: ((Time.now.to_f + expires_in) * 1000).to_i,
                           scopes: %w[user:inference user:profile],
                           subscriptionType: "max",
                           rateLimitTier: "default_claude_max_20x"
                         },
                         mcpOAuth: { server: { accessToken: "mcp" } }
                       ))
      result = yield
      [result, JSON.parse(File.read(path), symbolize_names: true)]
    ensure
      ENV["HOME"] = previous_home
    end
  end

  def json_response(status, body)
    TokenMaxx::Core::Http::Response.new(status: status, body: JSON.generate(body), headers: {})
  end
end
