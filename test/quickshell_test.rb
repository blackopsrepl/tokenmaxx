# frozen_string_literal: true

require_relative "test_helper"

class QuickShellTest < Minitest::Test
  def test_ui_adapter_only_writes_ui_state_on_explicit_actions
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))

    refute_match(
      /onAdapterUpdated\s*:\s*writeAdapter\(\)/,
      qml,
      "Rewriting ui.json on every adapter update clobbers the daemon-written open state"
    )
    assert_operator(
      qml.scan("writeAdapter()").length, :>=, 2,
      "Closing the panel and focusing a provider must still persist ui.json"
    )
  end

  # A glyph concatenated into a label string inherits the text font, and Fira Code
  # has no Nerd Font codepoints — fontconfig then resolves each glyph on its own,
  # which rendered the settings codicon as a stray mark beside a History clock that
  # happened to land on the icon font. Draw the glyph as its own Text.
  def test_icon_glyphs_are_not_concatenated_into_text_font_strings
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))

    refute_match(
      /text:\s*[^\n]*(?:root\.glyphs\.\w+|control\.glyph|tab\.glyph)[^\n]*\+/,
      qml,
      "a glyph inside a label string is drawn in the text font, not the icon font"
    )
    assert_operator qml.scan("font.family: root.iconFont").length, :>=, 4,
                    "the tab, button, note and rail-title glyphs all need the icon font"
  end

  # The trailing peak marker sits at the end of a row whose right edge is the
  # card's content edge — where the detail view's scrollbar overlays the card's
  # padding. Everyone renders it through PeakGlyph, which owns the fixed slot and
  # the right inset; a raw glyph at a row's end is drawn flush against that edge.
  def test_peak_markers_render_through_the_slotted_component
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))

    component = qml[/component PeakGlyph: Text \{.*?\n    \}/m]

    refute_nil component, "peak markers need the PeakGlyph component"
    assert_includes component, "Layout.preferredWidth:"
    assert_includes component, "Layout.rightMargin:", "the marker must be inset from the card's content edge"
    assert_includes component, "text: root.peakBadgeIcon(peak)"
    refute_match(
      /text: root\.peakBadgeIcon\(modelData\.peak\)/,
      qml,
      "a raw glyph at a row's end is drawn flush against the card's content edge"
    )
    assert_equal 2, qml.scan(/^\s+PeakGlyph \{$/).length,
                 "the overview card row and the model local usage row both need the marker"
  end

  def test_peak_row_labels_can_shrink_below_their_text_width
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))

    rows = qml.scan(/Layout\.fillWidth: true\n\s+Layout\.minimumWidth: 0\n(?:\s+.*\n)*?\s+elide: Text\.ElideRight/)

    assert_equal 2, rows.length,
                 "the label before a peak marker must elide instead of pushing the marker off the row"
  end

  def test_panel_actions_use_the_configured_executable
    qml = File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))

    assert_includes qml, 'var command = [root.tokenmaxxBin].concat(args).concat(["--config", root.configPath])'
    refute_includes qml, "root.config/tokenmaxxBin"
  end

  def test_running_pid_rejects_a_shell_command_that_only_mentions_the_qml_path
    config = build_config
    result = {
      stdout: "4321 /bin/zsh -c quickshell --path /installed/tokenmaxx/shell.qml\n",
      stderr: "",
      exitCode: 0
    }

    TokenMaxx::Runtime::QuickShell.stub(:resolve_shell_path, "/installed/tokenmaxx/shell.qml") do
      TokenMaxx::Runtime::QuickShell.stub(:resolve_quickshell_executable, "/usr/bin/quickshell") do
        TokenMaxx::Core::Process.stub(:run_command, result) do
          File.stub(:readlink, "/usr/bin/zsh") do
            assert_nil TokenMaxx::Runtime::QuickShell.running_pid(config)
          end
        end
      end
    end
  end

  def test_running_pid_accepts_the_quickshell_process_for_the_qml_path
    config = build_config
    result = {
      stdout: <<~OUTPUT,
        4321 /bin/zsh -c quickshell --path /installed/tokenmaxx/shell.qml
        9876 /usr/bin/quickshell --daemonize --path /installed/tokenmaxx/shell.qml
      OUTPUT
      stderr: "",
      exitCode: 0
    }
    executables = {
      "/proc/4321/exe" => "/usr/bin/zsh",
      "/proc/9876/exe" => "/usr/bin/quickshell"
    }

    TokenMaxx::Runtime::QuickShell.stub(:resolve_shell_path, "/installed/tokenmaxx/shell.qml") do
      TokenMaxx::Runtime::QuickShell.stub(:resolve_quickshell_executable, "/usr/bin/quickshell") do
        TokenMaxx::Core::Process.stub(:run_command, result) do
          File.stub(:readlink, ->(path) { executables.fetch(path) }) do
            assert_equal 9876, TokenMaxx::Runtime::QuickShell.running_pid(config)
          end
        end
      end
    end
  end

  QML_PATH = File.expand_path("../frontend/quickshell/shell.qml", __dir__)

  def qml_source
    @qml_source ||= File.read(QML_PATH)
  end

  # A mutation button that only queues a CLI command and returns leaves the
  # panel silent for the whole run: no pending state, and an error surfaces
  # only in qml debug logs the operator never sees. Every action runner
  # completion must resolve the pending state — with the command's stderr as
  # the error when the command failed — on the status surface.
  def test_action_feedback_surfaces_pending_and_terminal_results
    runner = qml_source[/Process \{\n        id: actionRunner\n(.*?)\n    \}\n\n    FileView \{\n        id: snapshotFile/m, 1]
    refute_nil runner, "the action lifecycle must live on the mutation Process"
    assert_operator(qml_source.scan(/id: actionRunnerError/).length, :>=, 1, "stderr needs a named collector")
    assert_match(/property string pendingAction: ""/, qml_source, "the panel needs a pending-action state")
    assert_match(/property string actionError: ""/, qml_source, "the panel needs an action error state")
    assert_match(/onStreamFinished: \(text\) => \{/, runner, "a finished stderr stream must end the action")
    assert_match(/onStreamFinished: \(text\) => \{[^}]*root\.actionFailed\(/m, runner,
                 "command stderr must land on the panel, not in swallowed debug logs")
    assert_match(/onExited: \(exitCode, exitStatus\) => \{/, runner, "process exit must end the action")
    assert_match(/root\.actionCompleted\("", exitCode\)/, runner, "a normal exit clears the pending state")
    assert_match(/function pendingActionText\(\)/, qml_source,
                 "pending and queued work must both be described on the status surface")
    assert_match(/function actionQueueDrain\(\)/, qml_source, "queued actions must drain after the in-flight command exits")
    assert_match(/visible: pendingActionVisible\(\)/, qml_source, "the status surface must appear and disappear with its text")
  end

  # Mutation buttons that call the multi-arg dispatch directly bypass the
  # queue lifecycle, so their work is invisible and their failures are
  # swallowed. Keep every mutation call site on the lifecycle-aware wrappers.
  def test_mutation_call_sites_use_the_lifecycle_aware_dispatch
    assert_match(/function scanCommand\(kind\)/, qml_source, "scan buttons need a labelled scan wrapper")
    assert_match(/function refreshAction\(\)/, qml_source, "the refresh button needs a labelled wrapper")
    assert_match(/function displayLabels\(\)/, qml_source, "display controls need a shared label bundle")

    assert_match(/onClicked: root\.refreshAction\(\)/, qml_source, "the header refresh button reports its pending state")
    assert_match(/onClicked: root\.scanCommand\("status"\)/, qml_source, "the header status button reports its pending state")
    assert_match(/onClicked: root\.scanCommand\("cost"\)/, qml_source, "the header usage button reports its pending state")

    refute_match(/onClicked: root\.runTokenMaxx\(/, qml_source,
                 "bare dispatch call sites bypass the pending/terminal feedback lifecycle")
    assert_operator(qml_source.scan(/onClicked: root\.displayCommand\(/).length, :>=, 10,
                    "both display control blocks must use the labelled wrapper")
    assert_operator(qml_source.scan(/onClicked: root\.runtimeCommand\(/).length, :>=, 6,
                    "both cadence control blocks must use the labelled wrapper")
    assert_operator(qml_source.scan(/root\.providerCommand\(/).length, :>=, 3,
                    "provider mutation buttons must keep the labelled wrapper")
  end

  # Status text must use the CLI's own command vocabulary so the panel, the
  # docs, and `tokenmaxx --help` describe the same actions.
  def test_mutation_labels_carry_verb_and_target
    [
      "Refreshing provider quota",
      "Scanning status",
      "Scanning usage",
      "Deactivating",
      "Hide ID",
      "Show ID",
      "Setting display mode"
    ].each do |label|
      assert_includes qml_source, label, "expected action vocabulary #{label.inspect} in the panel"
    end
  end

  # Under a narrow viewport the detail column plus the fixed 260 provider rail
  # squeeze the usage meters into unreadable slivers. Mirroring Switchyard's
  # breakpoint-driven layout: the fixed rail drops out (rail providers stay
  # selectable from the Provider Detail view) and the detail column takes the
  # freed width, while the header badge stack that cannot wrap hides under the
  # compact contract.
  def test_narrow_viewport_full_width_detail
    assert_match(/property bool narrowLayout:/, qml_source, "the panel needs a width breakpoint")
    assert_match(/width: Math\.min\(960, Math\.max\(320, panelWindow\.width - \(root\.narrowLayout \? 24 : 36\)\)\)/,
                 qml_source, "the modal must keep its usable width on narrow viewports")

    rail = qml_source[/CardFrame \{\n                            Layout\.preferredWidth: 260\n(.*?)\n                        \}\n                    \}\n\n                    CardFrame \{/m, 1]
    refute_nil rail, "the provider rail card block must exist"
    assert_match(/visible: !root\.narrowLayout/, rail, "the rail must drop out under the width breakpoint")

    header_badges = qml_source[/RowLayout \{\n                                Layout\.alignment: Qt\.AlignRight\n(.*?)minimumWidth: 34\n/m, 1]
    refute_nil header_badges, "the header badge stack must exist"
    assert_match(/visible: !root\.denseHeader/, header_badges, "the non-wrapping header badges must hide under the compact contract")
  end

  # The detail action rail (Focus/Provider/Display/Runtime button stack) is
  # fixed preferredWidth 500; on a narrow viewport it would leave the status
  # column an unreadable sliver, so it drops out with the compact layout too.
  def test_detail_action_rail_drops_out_when_narrow
    rail = qml_source[/CardFrame \{\n                        Layout\.fillWidth: true\n                        Layout\.preferredHeight: root\.dense \? 172 : 230\n(.*?)\n                    \}\n                \}\n            \}\n        \}\n    \}\n    \}\n\}/m, 1]

    refute_nil rail, "the detail action rail card block must exist"
    assert_match(/visible: root\.activeView === "detail" && !root\.narrowLayout/, rail, "the fixed-width action rail must drop out on narrow viewports")
  end

  # Keep the "dense" (height) and "narrow" (width) contracts apart: the rail
  # scrolls on short screens instead of ever stacking above the content.
  def test_dense_layout_never_stacks_provider_rail_above_content
    refute_match(/StackLayout/, qml_source, "the provider rail must scroll, never stack above the content")
  end

  # The shipped docs described a backdrop that has not existed since the
  # mac-bar modal landed: the input mask is bound to the modal frame, so clicks
  # outside the frame pass through to the desktop instead of dismissing. Pin
  # the honest wording everywhere the old claim appeared.
  def test_backdrop_dismissal_documentation_matches_input_mask
    [
      File.expand_path("../README.md", __dir__),
      File.expand_path("../WIREFRAME.md", __dir__),
      File.expand_path("../docs/ui.md", __dir__)
    ].each do |doc|
      body = File.read(doc)
      body.scan(/.*backdrop.*/i).each do |line|
        window = [line, body[/#{Regexp.escape(line.strip)}.*/m].to_s].join(" ")
        assert_match(/outside|through|mask/i, window,
                     "#{File.basename(doc)} still describes a dismissable dimmed backdrop: #{line.strip}")
      end
    end
  end

  # UI docs must carry the same status vocabulary as the panel and the CLI.
  def test_ui_docs_document_the_status_surface_and_queued_actions
    ui_doc = File.read(File.expand_path("../docs/ui.md", __dir__))

    assert_match(/pending and terminal results on a status line/, ui_doc,
                 "the status-line feedback contract belongs in the UI docs")
    assert_match(/command(?:'s)? stderr/, ui_doc, "the surfaced-stderr contract belongs in the UI docs")
    assert_match(/queue CLI mutations into a small FIFO instead of killing in-flight commands/, ui_doc)
    assert_match(/narrow 720 pixel breakpoint/, ui_doc,
                 "the narrow-viewport contract belongs in the UI docs")
  end
end
