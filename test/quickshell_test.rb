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
    assert_match(/function cardWidth\(\)/, qml_source, "the card carries a content-fit width function")
    assert_match(/Math\.max\(560,/, qml_source, "the card width keeps a usable narrow floor")

    refute_includes qml_source, "Layout.preferredWidth: 260"
    assert_includes qml_source, "id: providerPicker"
    assert_includes qml_source, "model: root.providerViews"

    header_badges = qml_source[/RowLayout \{\n                                Layout\.alignment: Qt\.AlignRight\n(.*?)minimumWidth: 34\n/m, 1]
    refute_nil header_badges, "the header badge stack must exist"
    assert_match(/visible: !root\.denseHeader/, header_badges, "the non-wrapping header badges must hide under the compact contract")
  end

  # The detail action rail (Focus/Provider/Display/Runtime button stack) is
  # fixed preferredWidth 500; on a narrow viewport it would leave the status
  # column an unreadable sliver, so it drops out with the compact layout too.
  def test_detail_action_rail_drops_out_when_narrow
    rail = qml_source[/CardFrame \{\n                        Layout\.fillWidth: true\n                        Layout\.preferredHeight: 176\n([\s\S]*?)\n                    \}\n                \}\n/m, 1]

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

  # The full-screen covering modal became a bounded bar drop-down: the
  # PanelWindow surface is exactly the strip the card needs (bar edge +
  # card rect), so the desktop underneath stays interactive without any
  # screen-wide surface, scrim, halo stack, or backdrop catcher. The card
  # hangs from the bar edge on the same side the Waybar chip occupies
  # (modules-left on a top bar): left-of-center, below the bar strip.
  # Verified anchor law (repobar/cronbar/backupbar render proofs): left+right
  # anchors force the surface to full screen width, so the bounded shape is
  # TOP-ONLY anchors + side margins.
  def test_panel_window_is_bounded_to_the_bar_drop_down
    window = qml_source[/PanelWindow \{\n        id: panelWindow\n([\s\S]*)\n    \}\n\}\n\z/m, 1]
    refute_nil window, "the panel's PanelWindow block must exist"

    assert_match(/anchors \{\n            top: true\n        \}/, window,
                 "the surface must anchor to the bar's edge only, never the full screen")
    refute_match(/bottom: true/, window, "a bounded drop-down never reaches the screen bottom")
    refute_match(/left: true/, window, "left/right anchors force a full-width surface")
    refute_match(/right: true/, window, "left/right anchors force a full-width surface")
    assert_includes qml_source, "property int dropDownTopMargin: 52"
    assert_match(/implicitWidth: root\.cardWidth\(\)/, window,
                 "the surface is exactly the card's width — not the bar's, not the screen's")
    assert_match(/implicitHeight: root\.cardHeight\(\)/, window,
                 "the surface height equals the card, with bar placement applied only by margins")
    refute_match(/anchors\.centerIn: parent/, window[/[\s\S]*?(?=
        FocusScope \{)/] || "", "the drop-down hangs from the bar, never floats centered mid-screen")
    refute_match(/mask:\s*Region/, window, "a bounded surface needs no clipped input mask; its own rect is the mask")
    assert_match(/WlrLayershell\.keyboardFocus: WlrKeyboardFocus\.OnDemand/, window)
    assert_includes window, "exclusionMode: ExclusionMode.Ignore"
  end

  # The card height is counted from the parts actually laid out — fixed
  # chrome, view-tab row, action row, badge stack and provider cards —
  # never from layout implicit sizes, and it is capped so the card stays a
  # bar drop-down rather than growing toward the screen height.
  def test_card_height_is_stable_and_capped_to_the_viewport
    body = qml_source[/function cardHeight\(\) \{(.*?)\n    \}/m, 1]
    refute_nil body
    assert_includes body, "return Math.min(root.dropDownMaxHeight, available)"
    assert_includes body, "screenHeight - root.dropDownTopMargin - 12"
    refute_match(/activeView|overviewProviders|providerGrid|railCard/, body)
    assert_includes qml_source, "property int dropDownMaxHeight: 820"
  end

  # The bar strip between the compositor's bar and the card is part of the
  # surface and is transparent, so it gets the dismissal catcher; the card
  # keeps its own catcher so dead space inside it stays inert. No
  # screen-wide Item, scrim, halo stack, or backdrop outside the card may
  # come back.
  def test_bounded_surface_applies_the_bar_margin_once
    assert_includes qml_source, "implicitHeight: root.cardHeight()"
    assert_includes qml_source, "anchors.topMargin: 0"
    refute_includes qml_source, "id: barStrip"
    assert_includes qml_source, "Keys.onEscapePressed: root.closePanel()"
  end

  # Keyboard dismissal is carried by the card's escape handler — the card is
  # the whole focusable surface now that no full-screen wrapper exists.
  def test_escape_is_a_window_shortcut_on_the_bounded_surface
    card = qml_source[/FocusScope \{\n            id: modalFrame\n([\s\S]*?)\n    \}\n\}\n\z/m, 1]

    assert_match(/Keys\.onEscapePressed: root\.closePanel\(\)/, card,
                 "Esc must dismiss the drop-down from the card surface")
  end

  # Family polish parity with switchyard 8cda212: the header carries a live
  # dot (red on error, amber while an action runs, soft-green otherwise)
  # and family-styled labelled Refresh/Close action buttons replace the
  # glyph-only buttons.
  def test_header_carries_the_live_dot_and_family_buttons
    header = qml_source[/CardFrame \{\n                        Layout\.fillWidth: true\n                        Layout\.preferredHeight: root\.dense \? 78 : 84\n(.*?)\n                        \}\n                    \}/m, 1]
    refute_nil header, "the header card block must exist"

    assert_match(/id: liveDot/, header, "the header needs the live dot")
    assert_match(/id: liveDot[\s\S]*?root\.actionError\.length > 0 \? root\.theme\.bad[\s\S]*?actionRunner\.running[\s\S]*?root\.theme\.good/, qml_source,
                 "the dot reads: red on error, amber in flight, soft-green idle")
    assert_match(/CodexButton \{[^}]*glyph: root\.glyphs\.refresh[^}]*onClicked: root\.refreshAction\(\)[^}]*\}/m, header,
                 "the header keeps the Refresh action button")
    assert_match(/CodexButton \{[^}]*glyph: root\.glyphs\.close[^}]*onClicked: root\.closePanel\(\)[^}]*\}/m, header,
                 "the header keeps the Close action button")
    assert_match(/ToolTip\.text: "Re-scan providers and refresh the cached snapshot"/, header,
                 "the Refresh button carries its tooltip")
    assert_match(/ToolTip\.text: "Close the panel \(Esc\)"/, header, "the Close button carries its tooltip")
    refute_match(/glyph: root\.glyphs\.refresh\n[^}]*\}\n\n\s*CodexButton \{\n\s*text: ""\n\s*glyph: root\.glyphs\.close\n\s*accent: root\.theme\.bad\n\s*compact: true\n\s*minimumWidth: 34\n\s*onClicked/m, header,
                 "the close glyph button must carry its tooltip too")
  end

  # Bounded-surface semantics must be documented honestly: the surface is the
  # bar drop-down's rect; clicks outside the card land on the desktop; the
  # bar-strip catcher and the Esc/Close affordances dismiss. The old
  # "input mask covers only the modal frame" claim retired with the mask.
  def test_docs_describe_the_bounded_bar_drop_down
    ui_doc = File.read(File.expand_path("../docs/ui.md", __dir__))

    refute_match(/Its input mask covers only the modal frame/, ui_doc,
                 "the mask claim retired with the full-screen surface")
    assert_match(/bounded bar drop-down/, ui_doc, "the shape belongs in the UI docs")
    assert_match(/hangs from the bar edge on the same side its Waybar chip occupies/, ui_doc,
                 "the chip-side placement contract belongs in the UI docs")
    assert_match(/Its height is stable across views and provider counts/i, ui_doc,
                 "the counted-height contract belongs in the UI docs")
    assert_match(/The desktop outside the surface stays interactive/, ui_doc,
                 "the bounded-surface interactivity contract belongs in the UI docs")
    assert_match(/click inside the popover to interact, Esc or the Close button to dismiss/, ui_doc,
                 "the honest dismissal trade belongs in the UI docs")
    assert_match(/the surface is transparent only over the card's own rect/, ui_doc,
                 "the transparent-card-surface note belongs in the UI docs")
  end

  # Family uniformity (the six *-bar sibling panels, modelled on this
  # panel's square-cornered mac-bar aesthetic): every Rectangle that
  # shapes a card, button, tab, badge, bar, or the panel shadow renders
  # with zero corner radius. The only nonzero radii left are shapes that
  # ARE dots, not corner rounding: circles-that-are-dots (the 7px
  # live/status dots at radius 3.5) and thin status stripes (radius
  # 1/1.5/2 on slivers of at most 8px). Any other radius leaks the old
  # rounded look back in.
  def test_family_surfaces_render_square_outside_dot_and_stripe_shapes
    strays = []

    qml_rectangles.each do |line_no, block|
      block.match(/^\s*radius:\s*([0-9.]+)\b/) or next
      radius = Regexp.last_match(1).to_f
      next if radius.zero?

      width = block[/(?:^|\s)(?:Layout\.preferred)?(?:W|w)idth:\s*([0-9.]+)\b/, 1]
      height = block[/(?:^|\s)(?:Layout\.preferred)?(?:H|h)eight:\s*([0-9.]+)\b/, 1]
      is_dot = width && height && width.to_f == height.to_f &&
               width.to_f <= 12 && radius == width.to_f / 2
      is_stripe = radius <= 2.0 && block[/\bheight:\s*([1-8](?:\.\d+)?)\b/, 1]

      strays << "line #{line_no}: radius #{radius}" unless is_dot || is_stripe
    end

    assert_empty strays.uniq,
                 "rounded corners leaked back into the square family surface: #{strays.uniq.join(', ')}"
  end

  # Family font scale (Switchyard's): one size per role so the six *-bar
  # panels read as one program — 9 secondary/meta, 10 body, 11 section and
  # card labels, 12 summary values, 15 detail headers and hero labels in
  # narrow chrome, 21 panel titles and big glyph ornaments. A size is only
  # exempt when its glyph is a tiny mark drawn small on purpose (the 7px
  # badge dot glyph). Ternary bindings must pick between scale values (the
  # dense header title keeps its 15/21 pair); delegate lines that inherit
  # another item's font carry no size of their own.
  FAMILY_FONT_SCALE = [9, 10, 11, 12, 15, 21].freeze

  def test_family_uses_the_shared_font_scale
    strays = []

    qml_source.each_line.with_index(1) do |line, line_no|
      line.match(/font\.pixelSize:\s*(\S+)/) or next
      value = Regexp.last_match(1)

      sizes = value.scan(/\d+/).map(&:to_i)
      next if sizes.empty? || sizes.all? { |size| size == 7 }

      strays << "line #{line_no}: font.pixelSize: #{value}" unless sizes.all? { |size| FAMILY_FONT_SCALE.include?(size) }
    end

    assert_empty strays,
                 "off-scale font sizes leaked back into the family panel: #{strays.join(', ')}"
  end

  # Smallest enclosing Rectangle-derived block for every `Rectangle {`
  # (component tail like `component CardFrame: Rectangle {` and property
  # tails like `background: Rectangle {` included), as [line_no, block].
  def qml_rectangles
    return @qml_rectangles if @qml_rectangles

    blocks = []
    lines = qml_source.lines
    index = 0
    while index < lines.length
      unless lines[index] =~ /^\s*(?:component\s+\w+\s*:\s*|[\w.]+:\s*)?Rectangle\s*\{/
        index += 1
        next
      end

      depth = lines[index].count("{") - lines[index].count("}")
      body = [+lines[index]]
      close = index + 1
      while depth.positive? && close < lines.length
        depth += lines[close].count("{") - lines[close].count("}")
        body << lines[close]
        close += 1
      end
      blocks << [index + 1, body.join]
      index = close
    end

    @qml_rectangles = blocks
  end
end

class ProviderLayoutStabilityTest < Minitest::Test
  def qml
    File.read(File.expand_path("../frontend/quickshell/shell.qml", __dir__))
  end

  def test_no_provider_count_or_view_can_resize_the_surface
    body = qml[/function cardHeight\(\) \{(.*?)\n    \}/m, 1]
    refute_match(/activeView|providerGrid|overviewProviders|railCard/, body)
    compact = qml[/function isCompact\(\) \{(.*?)\n    \}/m, 1]
    refute_match(/overviewProviders\(\)\.length/, compact)
  end

  def test_grid_uses_available_width_and_equal_columns
    block = qml[/id: providerGrid(.*?)Repeater/m, 1]
    assert_includes block, "uniformCellWidths: true"
    assert_includes block, "columns: root.overviewPageSize()"
    assert_includes qml, "model: root.overviewPageProviders()"
    assert_includes qml, 'text: "Next"'
  end

  def test_scroll_views_have_explicit_content_heights
    { "overviewScroll" => "overviewContent.implicitHeight + 24",
      "detailScroll" => "detailContent.implicitHeight + 24" }.each do |id, height|
      assert_includes qml, "id: #{id}\n                                    contentHeight: #{height}"
    end
  end

  def test_detail_actions_do_not_consume_the_reading_viewport
    assert_match(/Layout\.preferredHeight: 176\s+visible: root\.activeView === "detail"/, qml)
  end
end
