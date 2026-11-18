# frozen_string_literal: true

require_relative "test_helper"

class GeminiProviderTest < Minitest::Test
  def test_renewal_keeps_the_non_rotating_refresh_token_and_gemini_fields
    Dir.mktmpdir("tokenmaxx-gemini-creds") do |dir|
      path = File.join(dir, "oauth_creds.json")
      File.write(path, JSON.generate(access_token: "old", refresh_token: "google-rt", id_token: "old-id",
                                     scope: "openid", token_type: "Bearer",
                                     expiry_date: ((Time.now.to_f - 60) * 1000).to_i))
      store = TokenMaxx::Providers::Gemini.credential_store(path, dir)
      requests = []
      endpoint = Object.new
      endpoint.define_singleton_method(:request) do |_method, url, **options|
        requests << options.merge(url: url)
        TokenMaxx::Core::Http::Response.new(status: 200, headers: {},
                                             body: JSON.generate(access_token: "new", expires_in: 3599, id_token: "new-id"))
      end

      TokenMaxx::Providers::Gemini.stub(:find_oauth_client, { clientId: "cid", clientSecret: "secret" }) do
        token, doc = TokenMaxx::Core::OAuthRenewal.resolve(store, hold_dir: dir, http: endpoint)

        assert_equal "new", token
        assert_equal "google-rt", doc[:refresh_token]
        assert_equal "new-id", doc[:id_token]
        assert_equal "openid", doc[:scope]
      end
      assert_equal "https://oauth2.googleapis.com/token", requests.first[:url]
      assert_equal "google-rt", requests.first.dig(:form, :refresh_token)
      refute store.rotating
      assert_equal "new", JSON.parse(File.read(path))["access_token"]
    end
  end

  def test_oauth_client_is_read_from_bundled_gemini_cli_install
    Dir.mktmpdir("tokenmaxx-gemini-cli") do |dir|
      prefix = File.join(dir, "usr", "local")
      bin_dir = File.join(prefix, "bin")
      package_root = File.join(prefix, "lib", "node_modules", "@google", "gemini-cli")
      bundle_dir = File.join(package_root, "bundle")
      FileUtils.mkdir_p([bin_dir, bundle_dir])
      File.write(File.join(package_root, "package.json"), JSON.generate(name: "@google/gemini-cli"))
      File.write(File.join(bundle_dir, "gemini.js"), "#!/usr/bin/env node\n")
      File.write(
        File.join(bundle_dir, "chunk-test.js"),
        <<~JS
          var OAUTH_CLIENT_ID = "test-client.apps.googleusercontent.com";
          var OAUTH_CLIENT_SECRET = "test-secret";
        JS
      )
      File.symlink("../lib/node_modules/@google/gemini-cli/bundle/gemini.js", File.join(bin_dir, "gemini"))

      with_gemini_cli_path(File.join(bin_dir, "gemini")) do
        client = TokenMaxx::Providers::Gemini.find_oauth_client
        assert_equal "test-client.apps.googleusercontent.com", client[:clientId]
        assert_equal "test-secret", client[:clientSecret]
      end
    end
  end

  def test_quota_meters_preserve_each_model_bucket
    meters = TokenMaxx::Providers::Gemini.quota_meters([
      { modelId: "gemini-2.5-flash", remainingFraction: 1, resetTime: "2026-05-17T15:22:36Z" },
      { modelId: "gemini-2.5-pro", remainingFraction: 0, resetTime: "1970-01-01T00:00:00Z" },
      { modelId: "gemini-3.1-flash-lite-preview", remainingFraction: 0.998, resetTime: "2026-05-17T13:38:16Z" }
    ])

    assert_equal ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-3.1-flash-lite-preview"], meters.map { |meter| meter[:modelId] }
    assert_equal ["model:gemini-2.5-flash", "model:gemini-2.5-pro", "model:gemini-3.1-flash-lite-preview"], meters.map { |meter| meter[:key] }
    assert_equal 0.0, meters[0][:usedPercent]
    assert_equal 100.0, meters[1][:usedPercent]
    assert_nil meters[1][:resetsAt]
  end

  def test_auth_type_prefers_selected_auth_type_and_flags_unsupported_quota_modes
    provider = TokenMaxx::Providers::Gemini

    assert_equal "gemini-api-key", provider.gemini_auth_type(authType: "oauth-personal", selectedAuthType: "gemini-api-key")
    assert provider.unsupported_quota_auth_type?("gemini-api-key")
    assert provider.unsupported_quota_auth_type?("vertex-ai")
    refute provider.unsupported_quota_auth_type?("oauth-personal")
  end

  def test_http_error_message_surfaces_api_reason_and_status
    response = TokenMaxx::Core::Http::Response.new(
      status: 403,
      body: JSON.generate(
        error: {
          code: 403,
          status: "PERMISSION_DENIED",
          message: "You do not have a valid license of this product. (#3501)",
          details: [
            { "@type" => "type.googleapis.com/google.rpc.ErrorInfo", reason: "SUBSCRIPTION_REQUIRED" }
          ]
        }
      ),
      headers: {}
    )

    message = TokenMaxx::Providers::Gemini.http_error_message("Gemini quota request", response)

    assert_includes message, "Gemini quota request failed with HTTP 403"
    assert_includes message, "valid license"
    assert_includes message, "SUBSCRIPTION_REQUIRED"
  end

  def test_http_error_message_falls_back_when_body_is_not_json
    response = TokenMaxx::Core::Http::Response.new(status: 500, body: "<html>boom</html>", headers: {})

    assert_equal "Gemini quota request failed with HTTP 500",
                 TokenMaxx::Providers::Gemini.http_error_message("Gemini quota request", response)
  end

  def test_project_id_extraction_accepts_string_and_hash_shapes
    provider = TokenMaxx::Providers::Gemini

    assert_equal "project-a", provider.extract_project_id(cloudaicompanionProject: "project-a")
    assert_equal "project-b", provider.extract_project_id(cloudaicompanionProject: { id: "project-b" })
    assert_equal "project-c", provider.extract_project_id(cloudaicompanionProject: { projectId: "project-c" })
  end

  private

  def with_gemini_cli_path(path)
    previous = ENV["GEMINI_CLI_PATH"]
    ENV["GEMINI_CLI_PATH"] = path
    yield
  ensure
    ENV["GEMINI_CLI_PATH"] = previous
  end
end
