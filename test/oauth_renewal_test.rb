# frozen_string_literal: true

require_relative "test_helper"

class OAuthRenewalTest < Minitest::Test
  Renewal = TokenMaxx::Core::OAuthRenewal

  # Scripted token endpoint: each entry is a Response to return or an
  # exception class to raise; every call is recorded.
  class ScriptedEndpoint
    attr_reader :calls

    def initialize(*script)
      @script = script
      @calls = []
    end

    def request(method, url, **options)
      @calls << options.merge(method: method, url: url)
      step = @script.shift
      raise "unexpected token request" if step.nil?
      raise step, "scripted" if step.is_a?(Class)

      step
    end
  end

  def setup
    @dir = Dir.mktmpdir("tokenmaxx-oauth")
    @path = File.join(@dir, "creds.json")
    @hold_dir = File.join(@dir, "state")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_fresh_access_token_is_used_without_contacting_the_endpoint
    write_creds(access: "live", refresh: "rt-1", expires_in: 3600)
    endpoint = ScriptedEndpoint.new

    token, = resolve(endpoint)

    assert_equal "live", token
    assert_empty endpoint.calls
  end

  def test_renews_inside_the_margin_and_commits_the_rotated_pair_atomically
    write_creds(access: "old", refresh: "rt-1", expires_in: 120, extra: { subscriptionType: "max" })
    endpoint = ScriptedEndpoint.new(token_response(access: "new", refresh: "rt-2"))

    token, doc = resolve(endpoint)

    assert_equal "new", token
    assert_equal "rt-1", endpoint.calls.first.dig(:json, :refresh_token)
    stored = JSON.parse(File.read(@path), symbolize_names: true)
    assert_equal "rt-2", stored.dig(:oauth, :refreshToken)
    assert_equal "max", stored.dig(:oauth, :subscriptionType)
    assert_equal "keep-me", stored[:otherTool]
    assert_equal stored, doc
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_empty Dir.glob(File.join(@dir, "*.tmp"))
    assert_empty holds
  end

  def test_adopts_a_renewal_another_client_made_while_holding_the_lock
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    lock_dir = File.join(@dir, ".refresh.lock")
    Dir.mkdir(lock_dir)
    other_client = lambda do |_seconds|
      write_creds(access: "theirs", refresh: "rt-2", expires_in: 3600)
      FileUtils.rm_rf(lock_dir)
    end
    endpoint = ScriptedEndpoint.new

    token, = resolve(endpoint, locks: [{ kind: :mkdir, path: lock_dir }], sleeper: other_client)

    assert_equal "theirs", token
    assert_empty endpoint.calls
    refute File.exist?(lock_dir)
  end

  def test_rejected_refresh_token_needs_sign_in_and_is_never_sent_again
    write_creds(access: "old", refresh: "rt-dead", expires_in: -60)
    endpoint = ScriptedEndpoint.new(response(400, error: "invalid_grant", error_description: "Refresh token expired"))

    error = assert_raises(Renewal::LoginExpired) { resolve(endpoint) }
    assert_match "Spec login needs a new sign-in: the refresh token was rejected", error.message
    assert_match "Sign in again.", error.message

    second = assert_raises(Renewal::LoginExpired) { resolve(endpoint) }
    assert_equal error.message, second.message
    assert_equal 1, endpoint.calls.length
  end

  def test_a_new_login_in_the_file_gets_past_an_old_hold
    write_creds(access: "old", refresh: "rt-dead", expires_in: -60)
    assert_raises(Renewal::LoginExpired) do
      resolve(ScriptedEndpoint.new(response(400, error: "invalid_grant")))
    end

    write_creds(access: "relogin", refresh: "rt-fresh", expires_in: -60)
    token, = resolve(ScriptedEndpoint.new(token_response(access: "renewed", refresh: "rt-next")))

    assert_equal "renewed", token
  end

  def test_refusal_that_keeps_the_refresh_token_lifts_the_hold
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    paused = response(503, { type: "error" }, "retry-after" => "30")
    endpoint = ScriptedEndpoint.new(paused, token_response(access: "new", refresh: "rt-2"))

    assert_raises(Renewal::RenewalFailed) { resolve(endpoint) }
    assert_empty holds
    token, = resolve(endpoint)

    assert_equal "new", token
    assert_equal 2, endpoint.calls.length
  end

  def test_dropped_answer_is_resent_once_inside_the_window
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    endpoint = ScriptedEndpoint.new(Errno::ECONNRESET, token_response(access: "new", refresh: "rt-2"))

    token, = resolve(endpoint, clock: ticking_clock(5))

    assert_equal "new", token
    assert_equal(%w[rt-1 rt-1], endpoint.calls.map { |call| call.dig(:json, :refresh_token) })
    assert_empty holds
  end

  def test_lost_answer_after_the_window_holds_the_token_without_resending
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    endpoint = ScriptedEndpoint.new(response(502, {}))

    error = assert_raises(Renewal::LoginExpired) { resolve(endpoint, clock: ticking_clock(31)) }
    assert_match "may already be spent", error.message
    assert_raises(Renewal::LoginExpired) { resolve(endpoint) }

    assert_equal 1, endpoint.calls.length
  end

  def test_timeout_holds_the_token_without_resending
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    endpoint = ScriptedEndpoint.new(Net::ReadTimeout)

    error = assert_raises(Renewal::LoginExpired) { resolve(endpoint) }

    assert_match "a renewal timed out", error.message
    assert_equal 1, endpoint.calls.length
  end

  def test_second_failed_answer_holds_the_token
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    endpoint = ScriptedEndpoint.new(Errno::ECONNRESET, response(400, error: "invalid_grant"))

    error = assert_raises(Renewal::LoginExpired) { resolve(endpoint, clock: ticking_clock(1)) }

    assert_match "two renewals got no usable answer", error.message
  end

  def test_unreachable_endpoint_is_retried_next_refresh
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    endpoint = ScriptedEndpoint.new(Net::OpenTimeout, token_response(access: "new", refresh: "rt-2"))

    assert_raises(Renewal::RenewalFailed) { resolve(endpoint) }
    assert_empty holds
    token, = resolve(endpoint)

    assert_equal "new", token
  end

  def test_non_rotating_token_is_never_held
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    endpoint = ScriptedEndpoint.new(Net::ReadTimeout, token_response(access: "new", refresh: nil))

    assert_raises(Renewal::RenewalFailed) { resolve(endpoint, rotating: false) }
    token, = resolve(endpoint, rotating: false)

    assert_equal "new", token
    assert_equal "rt-1", JSON.parse(File.read(@path), symbolize_names: true).dig(:oauth, :refreshToken)
  end

  def test_busy_lock_keeps_a_still_valid_token
    write_creds(access: "valid-for-a-bit", refresh: "rt-1", expires_in: 60)
    lock = File.join(@dir, ".held.lock")
    Dir.mkdir(lock)

    token, = resolve(ScriptedEndpoint.new, locks: [{ kind: :mkdir, path: lock }], sleeper: ->(_) {})

    assert_equal "valid-for-a-bit", token
  end

  def test_busy_lock_with_an_expired_token_reports_a_transient_failure
    write_creds(access: "expired", refresh: "rt-1", expires_in: -60)
    lock = File.join(@dir, ".held.lock")
    Dir.mkdir(lock)

    assert_raises(Renewal::RenewalFailed) do
      resolve(ScriptedEndpoint.new, locks: [{ kind: :mkdir, path: lock }], sleeper: ->(_) {})
    end
  end

  def test_stale_mkdir_lock_from_a_dead_holder_is_taken_over
    write_creds(access: "old", refresh: "rt-1", expires_in: -60)
    lock = File.join(@dir, ".stale.lock")
    Dir.mkdir(lock)
    File.utime(Time.now - 120, Time.now - 120, lock)

    token, = resolve(ScriptedEndpoint.new(token_response(access: "new", refresh: "rt-2")),
                     locks: [{ kind: :mkdir, path: lock }])

    assert_equal "new", token
    refute File.exist?(lock)
  end

  def test_missing_credentials_need_sign_in
    error = assert_raises(Renewal::LoginExpired) { resolve(ScriptedEndpoint.new) }

    assert_match "no credentials at", error.message
  end

  private

  def resolve(endpoint, locks: [], rotating: true, sleeper: ->(_) {}, clock: ticking_clock(0))
    Renewal.resolve(store(locks: locks, rotating: rotating), hold_dir: @hold_dir, http: endpoint,
                                                             sleeper: sleeper, clock: clock)
  end

  def store(locks:, rotating:)
    Renewal::Store.new(
      id: "spec",
      label: "Spec",
      path: @path,
      locks: locks,
      rotating: rotating,
      login_hint: "Sign in again.",
      read_credential: lambda do |doc|
        oauth = doc[:oauth] || {}
        { access_token: oauth[:accessToken].to_s, refresh_token: oauth[:refreshToken].to_s,
          expires_at: Time.at(oauth[:expiresAt].to_f / 1000.0) }
      end,
      request: ->(credential, _doc) { { url: "https://auth.example/token", json: { refresh_token: credential[:refresh_token] } } },
      apply: lambda do |doc, body, issued_at|
        oauth = doc[:oauth].merge(accessToken: body[:access_token],
                                  refreshToken: body[:refresh_token] || doc.dig(:oauth, :refreshToken),
                                  expiresAt: (issued_at.to_f * 1000).to_i + body[:expires_in].to_i * 1000)
        doc.merge(oauth: oauth)
      end
    )
  end

  def write_creds(access:, refresh:, expires_in:, extra: {})
    oauth = { accessToken: access, refreshToken: refresh, expiresAt: ((Time.now.to_f + expires_in) * 1000).to_i }
    File.write(@path, JSON.generate(oauth: oauth.merge(extra), otherTool: "keep-me"))
  end

  def token_response(access:, refresh:)
    response(200, { access_token: access, refresh_token: refresh, expires_in: 28_800 }.compact)
  end

  def response(status, body, headers = {})
    TokenMaxx::Core::Http::Response.new(status: status, body: JSON.generate(body), headers: headers)
  end

  # Each reading advances by `step` seconds.
  def ticking_clock(step)
    now = 0.0
    lambda do
      current = now
      now += step
      current
    end
  end

  def holds
    path = File.join(@hold_dir, "oauth-holds", "spec.json")
    File.exist?(path) ? JSON.parse(File.read(path)) : {}
  end
end
