# frozen_string_literal: true

require_relative "test_helper"
require "open3"

class ReleaseTest < Minitest::Test
  # `make install` copies INSTALL_FILES only, so a lib file missing from it loads in
  # the source tree and every test, then crashes the installed daemon on require.
  def test_install_manifest_ships_every_runtime_source
    makefile = File.read(File.expand_path("../Makefile", __dir__))
    manifest = makefile[/^INSTALL_FILES := \\\n((?:\t[^\n]*\\\n)*\t[^\n]*)\n/, 1].to_s.split.reject { |entry| entry == "\\" }
    root = File.expand_path("..", __dir__)
    sources = Dir.glob("lib/**/*.rb", base: root) + ["frontend/quickshell/shell.qml", "bin/tokenmaxx"]

    assert_empty sources - manifest, "INSTALL_FILES is missing runtime sources"
  end

  def test_notes_read_only_the_requested_tag_and_fail_closed
    script = File.expand_path("../bin/release-notes", __dir__)
    Dir.mktmpdir("tokenmaxx-release") do |dir|
      git = lambda do |*args|
        output, error, status = Open3.capture3("git", "-c", "user.name=Release Test", "-c", "user.email=release@example.invalid", *args, chdir: dir)
        assert status.success?, "#{args.inspect}: #{output} #{error}"
      end
      git.call("init", "--quiet")
      # Synthetic history tests extraction without relying on repository tags.
      File.write(File.join(dir, "CHANGELOG.md"), "# Changelog\n\n## [2.6.0](https://example.invalid/compare)\n\n### Features\n\n* Scoped status\n\n## [2.5.3]\n\n* Previous change\n")
      git.call("add", "CHANGELOG.md")
      git.call("commit", "--quiet", "-m", "test: record release notes")
      git.call("tag", "v2.6.0")
      output, error, status = Open3.capture3("ruby", script, "v2.6.0", chdir: dir)
      assert status.success?, error
      assert_includes output, "Scoped status"
      refute_includes output, "Previous change"
      File.write(File.join(dir, "CHANGELOG.md"), "# Uncommitted content must not publish\n")
      again, = Open3.capture3("ruby", script, "v2.6.0", chdir: dir)
      assert_equal output, again
      git.call("tag", "v8.8.8")
      missing, error, status = Open3.capture3("ruby", script, "v8.8.8", chdir: dir)
      refute status.success?
      assert_empty missing
      assert_includes error, "No changelog section"
      File.write(File.join(dir, "CHANGELOG.md"), "# Changelog\n\n## [2.7.0]\n\nCompare only; no entries.\n")
      git.call("add", "CHANGELOG.md")
      git.call("commit", "--quiet", "-m", "test: record empty notes")
      git.call("tag", "v2.7.0")
      empty, error, status = Open3.capture3("ruby", script, "v2.7.0", chdir: dir)
      refute status.success?
      assert_empty empty
      assert_includes error, "no release entries"
      _, error, status = Open3.capture3("ruby", script, "--all", chdir: dir)
      refute status.success?
      assert_includes error, "Usage:"
    end
  end
end
