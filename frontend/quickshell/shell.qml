//@ pragma IconTheme Papirus-Dark

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    property string configPath: Quickshell.env("TOKENMAXX_CONFIG") || ((Quickshell.env("HOME") || "") + "/.config/tokenmaxx/config.json")
    property string stateDir: Quickshell.env("TOKENMAXX_STATE_DIR") || ((Quickshell.env("HOME") || "") + "/.local/state/tokenmaxx")
    property string tokenmaxxBin: Quickshell.env("TOKENMAXX_BIN") || "tokenmaxx"
    property string snapshotPath: stateDir + "/snapshot.json"
    property string uiPath: stateDir + "/ui.json"
    property string textFont: "Fira Code"
    property string iconFont: "Symbols Nerd Font Mono"

    // Omarchy theme wiring: live-follows the active Omarchy theme palette
    // (the same colors.toml the Omarchy shell reads). Falls back to the
    // built-in palette where a key is absent or Omarchy is not running.
    property string themeColorsPath: Quickshell.env("OMARCHY_THEME_COLORS") || ((Quickshell.env("HOME") || "") + "/.local/state/omarchy/current/theme/colors.toml")
    property var themePalette: ({})

    function applyThemeColors(raw) {
        var parsed = {}
        var lines = String(raw || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
            var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
            if (match)
                parsed[match[1]] = match[2]
        }
        root.themePalette = parsed
    }

    function themeColor(key, fallback) {
        var value = root.themePalette[key]
        return (typeof value === "string" && value.length > 0) ? value : fallback
    }

    // Derives a darker step of a theme color so multi-level fills (the token
    // heatmaps) keep distinct shades. Falls back to the built-in literal.
    function themeShade(key, fallback, factor) {
        var value = root.themePalette[key]
        return (typeof value === "string" && value.length > 0) ? Qt.darker(value, factor) : fallback
    }

    readonly property QtObject theme: QtObject {
        readonly property color bg: root.themeColor("background", "#0B0F1E")
        readonly property color bgDeep: root.themeColor("dark_background", "#050711")
        readonly property color surface: root.themeColor("selection", "#0E1423")
        readonly property color surfaceHi: root.themeColor("lighter_background", "#12182B")
        readonly property color surfaceDeep: root.themeColor("dark_background", "#101726")
        readonly property color border: root.themeColor("muted", "#232C45")
        readonly property color text: root.themeColor("bright_foreground", "#F6FBFF")
        readonly property color textSoft: root.themeColor("bright_foreground", "#DDF7FF")
        readonly property color textBody: root.themeColor("foreground", "#C4D2ED")
        readonly property color textDim: root.themeColor("foreground", "#8E97B5")
        readonly property color textMuted: root.themeColor("dark_foreground", "#6A6E95")
        readonly property color good: root.themeColor("green", "#82FB9C")
        readonly property color goodMid: root.themeShade("green", "#45C878", 1.5)
        readonly property color goodDeep: root.themeShade("green", "#237A50", 2.1)
        readonly property color goodBg: root.themeShade("green", "#1D3B2F", 3.0)
        readonly property color info: root.themeColor("accent", "#82A7F4")
        readonly property color warn: root.themeColor("yellow", "#F2C572")
        readonly property color bad: root.themeColor("red", "#E06C75")
        readonly property color badSoft: root.themeColor("red", "#F6B7BF")
    }

    FileView {
        id: themeFile
        path: root.themeColorsPath
        watchChanges: true
        printErrors: false
        onLoaded: root.applyThemeColors(text())
        onFileChanged: reload()
        onLoadFailed: root.applyThemeColors("")
    }

    property var glyphs: ({
        refresh: "",
        close: "",
        pin: "",
        pinned: "",
        auto: "",
        hidden: "",
        shown: "",
        overview: "",
        dashboard: "",
        provider: "",
        display: "",
        note: "",
        alert: "󰀨",
        meter: "",
        status: "",
        history: "",
        settings: "",
        bell: "",
        privacy: "",
        storage: "",
        cost: "",
        peak: "󰖙",
        offpeak: "󰖔"
    })

    property var viewData: snapshotAdapter.view && snapshotAdapter.view.summary ? snapshotAdapter.view : ({ summary: {}, chip: {}, providers: [] })
    property var providerViews: viewData.providers || []
    property string focusProviderId: ""
    property string activeView: "overview"
    // Low-resolution displays (1366x768 and similar laptops) cannot fit the
    // relaxed chrome, so the panel tightens margins, the header, and the
    // detail action panel instead of squeezing the content area to a sliver.
    property bool dense: panelWindow.height > 0 && panelWindow.height < 820
    // Peak state resolves against the panel's own clock from timezone-absolute
    // compiled timelines in peakSchedules, so it is exact at every boundary and
    // DST/odd-offset correct without repeating the schedule here. The timer is
    // armed to the next transition rather than polling, so it costs nothing
    // while the state holds.
    property double nowMs: Date.now()
    property var peakSchedules: viewData.peakSchedules || ({})

    onPeakSchedulesChanged: peakClock.arm()

    Timer {
        id: peakClock
        repeat: false
        running: false
        onTriggered: {
            root.nowMs = Date.now()
            root.peakClock.arm()
        }

        function nextTransitionMs() {
            var schedules = root.peakSchedules
            if (!schedules) {
                return null
            }
            var earliest = null
            var ids = Object.keys(schedules)
            for (var i = 0; i < ids.length; i += 1) {
                var schedule = schedules[ids[i]]
                var transitions = schedule && schedule.transitions ? schedule.transitions : []
                for (var j = 0; j < transitions.length; j += 1) {
                    var at = transitions[j][0] * 1000
                    if (at > root.nowMs && (earliest === null || at < earliest)) {
                        earliest = at
                    }
                }
            }
            return earliest
        }

        function arm() {
            // Refresh the clock reading on every arm so a snapshot refresh also
            // re-renders the label, not only a boundary crossing.
            root.nowMs = Date.now()
            var next = nextTransitionMs()
            if (next === null) {
                running = false
                return
            }
            // Fire just after the boundary so the resolution is unambiguous.
            var untilNext = Math.ceil(next - root.nowMs) + 250
            // Cap the sleep so a clock jump (NTP step, suspend/resume) self-heals
            // within an hour instead of persisting until the next boundary.
            interval = Math.max(500, Math.min(untilNext, 3600000))
            restart()
        }
    }

    function peakScheduleFor(id) {
        return id ? root.peakSchedules[id] : null
    }

    // Resolves a provider/model peak object against the panel clock. The last
    // transition at or before now is the current state; the next transition is
    // the end of the current window. When the snapshot carries no compiled
    // timeline for the peak (version skew until the next daemon refresh), the
    // static label/state/window fields the presenter rendered into the
    // snapshot keep every peak surface working.
    function peakResolved(peak) {
        if (!peak) {
            return null
        }

        var resolved = timelinePeakResolved(peak)
        if (resolved) {
            return resolved
        }

        var state = peak.state === "peak" || peak.state === "offpeak" ? peak.state : ""
        if (!state) {
            return null
        }

        var inPeak = state === "peak"
        return {
            inPeak: inPeak,
            label: inPeak ? "Peak" : "Off-peak",
            state: state,
            windowText: peak.windowText ? String(peak.windowText) : "",
            detail: peak.detail ? String(peak.detail) : ""
        }
    }

    function timelinePeakResolved(peak) {
        if (!peak || !peak.scheduleId) {
            return null
        }

        var schedule = root.peakScheduleFor(peak.scheduleId)
        if (!schedule || !schedule.transitions || !schedule.transitions.length) {
            return null
        }

        var transitions = schedule.transitions
        var inPeak = transitions[0][1] === 1
        var startMs = null
        var endMs = null
        for (var i = 0; i < transitions.length; i += 1) {
            var at = transitions[i][0] * 1000
            if (at <= root.nowMs) {
                inPeak = transitions[i][1] === 1
                startMs = at
            } else {
                endMs = at
                break
            }
        }

        if (endMs === null && transitions.length) {
            endMs = transitions[transitions.length - 1][0] * 1000
        }

        return {
            inPeak: inPeak,
            label: inPeak ? "Peak" : "Off-peak",
            state: inPeak ? "peak" : "offpeak",
            windowText: (startMs !== null && endMs !== null) ? root.localSpan(startMs, endMs) : "",
            detail: schedule.detail || ""
        }
    }

    function localSpan(startMs, endMs) {
        var start = new Date(startMs)
        var end = new Date(endMs)
        var sameDay = start.toDateString() === end.toDateString()
        var startText = Qt.formatDateTime(start, "ddd HH:mm")
        var endText = sameDay ? Qt.formatDateTime(end, "HH:mm") : Qt.formatDateTime(end, "ddd HH:mm")
        return startText + "\u2013" + endText
    }

    function peakBadgeLabel(peak) {
        var resolved = root.peakResolved(peak)
        return resolved ? resolved.label : ""
    }

    function peakBadgeDetail(peak) {
        var resolved = root.peakResolved(peak)
        if (!resolved) {
            return ""
        }
        var prefix = resolved.inPeak ? "Peak now" : "Off-peak now"
        return resolved.windowText ? (prefix + " \u00b7 " + resolved.windowText + " local") : prefix
    }

    function peakBadgeIcon(peak) {
        var resolved = root.peakResolved(peak)
        if (!resolved) {
            return ""
        }
        return resolved.inPeak ? root.glyphs.peak : root.glyphs.offpeak
    }

    function peakBadgeAccent(peak) {
        var resolved = root.peakResolved(peak)
        return resolved && resolved.inPeak ? root.theme.warn : root.theme.good
    }

    // Live value/detail for the "Rate period" card, resolved from the schedule
    // id alone so the card tracks the panel clock even when the snapshot is old.
    function peakCardLive(scheduleId) {
        var resolved = root.peakResolved({ scheduleId: scheduleId })
        if (!resolved) {
            return null
        }
        var detail = resolved.detail || ""
        if (resolved.windowText) {
            detail = resolved.windowText + " local" + (detail ? " \u00b7 " + detail : "")
        }
        return { value: resolved.label, detail: detail }
    }

    function accentColor(provider) {
        return provider && provider.accent ? provider.accent : root.theme.good
    }

    function withAlpha(hex, alpha) {
        var value = hex
        if (value && typeof value !== "string") {
            value = value.toString()
        }

        if (!value || value.length < 7) {
            return Qt.rgba(0.5, 0.98, 0.61, alpha)
        }

        var r = parseInt(value.slice(1, 3), 16) / 255
        var g = parseInt(value.slice(3, 5), 16) / 255
        var b = parseInt(value.slice(5, 7), 16) / 255
        return Qt.rgba(r, g, b, alpha)
    }

    function statusColor(provider) {
        if (!provider) {
            return root.theme.textMuted
        }
        if (provider.status === "error" || provider.status === "critical") {
            return root.theme.bad
        }
        if (provider.status === "warning") {
            return root.theme.warn
        }
        if (provider.status === "incident") {
            return root.theme.info
        }
        if (provider.status === "stale" || provider.status === "loading") {
            return root.theme.textMuted
        }

        return accentColor(provider)
    }

    function historyHeatmap() {
        var provider = focusProvider()
        return provider && provider.historyHeatmap && provider.historyHeatmap.available ? provider.historyHeatmap : null
    }

    function heatmapStatsLine(heatmap) {
        var stats = heatmap && heatmap.stats ? heatmap.stats : null
        if (!stats || !stats.windowText) {
            return ""
        }
        var peak = String(stats.bestCountText || "0 tok").replace(" tok", "")
        return stats.windowText + " · " + (stats.activeDays || 0) + " active · streak " + (stats.currentStreak || 0) + " · best " + (stats.bestDayText || "none") + " · " + peak
    }

    function heatmapColor(cell) {
        if (!cell || cell.empty) {
            return root.theme.surface
        }
        if (!cell.present) {
            return root.theme.border
        }
        if (cell.intensity >= 4) {
            return root.theme.good
        }
        if (cell.intensity === 3) {
            return root.theme.goodMid
        }
        if (cell.intensity === 2) {
            return root.theme.goodDeep
        }
        if (cell.intensity === 1) {
            return root.theme.goodBg
        }
        return root.theme.border
    }

    function runTokenMaxx(args) {
        var command = [root.tokenmaxxBin].concat(args).concat(["--config", root.configPath])
        if (actionRunner.running) {
            if (actionRunner.queue.length < 8) {
                actionRunner.queue.push(command)
            }
            return
        }

        actionRunner.command = command
        actionRunner.running = true
    }

    function displayProvider() {
        var displayId = snapshotAdapter.displayProvider || ""
        var provider = findProvider(displayId)
        return provider || firstUsableProvider()
    }

    function firstUsableProvider() {
        var index

        for (index = 0; index < providerViews.length; index += 1) {
            if (providerViews[index].enabled && providerViews[index].visible) {
                return providerViews[index]
            }
        }

        return providerViews.length ? providerViews[0] : null
    }

    function findProvider(providerId) {
        var index

        for (index = 0; index < providerViews.length; index += 1) {
            if (providerViews[index].id === providerId) {
                return providerViews[index]
            }
        }

        return null
    }

    function focusProvider() {
        return findProvider(focusProviderId) || displayProvider()
    }

    function setView(viewName) {
        activeView = viewName
        if (viewName === "detail") {
            syncFocus()
        }
    }

    function providerHistory() {
        var provider = focusProvider()
        return provider && provider.historyDays ? provider.historyDays : []
    }

    function cacheCommand(target) {
        runTokenMaxx(["cache", "clear", target])
    }

    function compactJoin(parts) {
        var output = []
        var index
        for (index = 0; index < parts.length; index += 1) {
            if (parts[index]) {
                output.push(parts[index])
            }
        }
        return output.join("  /  ")
    }

    function overviewProviders() {
        var providers = []
        var index

        for (index = 0; index < providerViews.length; index += 1) {
            if (providerViews[index].enabled && providerViews[index].visible && providerViews[index].inOverview) {
                providers.push(providerViews[index])
            }
        }

        return providers
    }

    function fallbackFocusId() {
        if (uiAdapter.focusProvider && findProvider(uiAdapter.focusProvider)) {
            return uiAdapter.focusProvider
        }

        var display = displayProvider()
        if (display) {
            return display.id
        }

        return providerViews.length ? providerViews[0].id : ""
    }

    function syncFocus() {
        if (!providerViews.length) {
            focusProviderId = ""
            return
        }

        focusProviderId = fallbackFocusId()
    }

    function setFocus(providerId) {
        if (!providerId) {
            syncFocus()
            return
        }

        focusProviderId = providerId
        if (uiAdapter.focusProvider !== providerId) {
            uiAdapter.focusProvider = providerId
            uiFile.writeAdapter()
        }
    }

    function closePanel() {
        uiAdapter.open = false
        uiFile.writeAdapter()
    }

    function providerCommand(action, providerId) {
        runTokenMaxx(["providers", action, providerId])
    }

    function overviewCommand(action, providerId) {
        runTokenMaxx(["providers", "overview", action, providerId])
    }

    function displayCommand(action, value) {
        var args = ["display", action]
        if (value) {
            args.push(value)
        }
        runTokenMaxx(args)
    }

    function runtimeCommand(mode, seconds) {
        var args = ["runtime", "cadence", mode]
        if (seconds) {
            args.push(seconds)
        }
        runTokenMaxx(args)
    }

    function notificationCommand(enabled) {
        runTokenMaxx(["notifications", enabled ? "enable" : "disable"])
    }

    function privacyCommand(hidden) {
        runTokenMaxx(["privacy", hidden ? "hide" : "show"])
    }

    Process {
        id: actionRunner
        property var queue: []
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length) {
                    console.log(text.trim())
                }
            }
        }
        onRunningChanged: {
            if (!running && queue.length) {
                command = queue.shift()
                running = true
            }
        }
    }

    FileView {
        id: snapshotFile
        path: root.snapshotPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: snapshotAdapter
            property string generatedAt: ""
            property var enabledProviders: []
            property var visibleProviders: []
            property var hiddenProviders: []
            property var overviewProviders: []
            property var autoSelectableProviders: []
            property string selectedProvider: ""
            property string displayProvider: ""
            property var results: ({})
            property var view: ({})
        }
    }

    FileView {
        id: uiFile
        path: root.uiPath
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: uiAdapter
            property bool open: false
            property string focusProvider: ""
            property string requestedAt: ""

            onOpenChanged: {
                if (open) {
                    root.syncFocus()
                }
            }

            onFocusProviderChanged: root.syncFocus()
        }
    }

    Component.onCompleted: {
        snapshotFile.reload()
        uiFile.reload()
        peakClock.arm()
    }

    component CodexButton: Button {
        id: control
        property color accent: root.theme.good
        property string glyph: ""
        property bool compact: false
        property int minimumWidth: compact ? 74 : 92

        font.family: root.textFont
        font.pixelSize: compact ? 10 : 11
        hoverEnabled: true
        padding: 0
        implicitHeight: compact ? 26 : 30
        implicitWidth: Math.max(minimumWidth, contentItem.implicitWidth + 18)

        background: Rectangle {
            radius: 3
            color: control.down ? withAlpha(control.accent, 0.26) : (control.hovered ? withAlpha(control.accent, 0.18) : withAlpha(control.accent, 0.10))
            border.color: control.hovered ? withAlpha(control.accent, 0.60) : withAlpha(control.accent, 0.34)
            border.width: 1

            Behavior on color {
                ColorAnimation { duration: 110 }
            }

            Behavior on border.color {
                ColorAnimation { duration: 110 }
            }
        }

        // The glyph and the label are separate runs so each gets its own font:
        // Fira Code has no Nerd Font codepoints, and leaving a glyph to
        // fontconfig's per-character fallback resolves some of them in unrelated
        // fonts (U+EB51 came out as a stray mark instead of the settings gear).
        contentItem: Item {
            implicitWidth: controlRow.implicitWidth
            implicitHeight: controlRow.implicitHeight

            RowLayout {
                id: controlRow
                anchors.centerIn: parent
                spacing: 6

                Text {
                    visible: !!control.glyph
                    text: control.glyph
                    color: root.theme.textSoft
                    font.family: root.iconFont
                    font.pixelSize: control.font.pixelSize
                }

                Label {
                    text: control.text
                    color: root.theme.textSoft
                    font.family: root.textFont
                    font.pixelSize: control.font.pixelSize
                    font.bold: control.font.bold
                }
            }
        }
    }

    component ViewTab: Button {
        id: tab
        property string view: ""
        property string glyph: ""
        property color accent: root.theme.good
        property bool selected: root.activeView === view

        font.family: root.textFont
        font.pixelSize: 11
        font.bold: selected
        hoverEnabled: true
        padding: 0
        implicitHeight: root.dense ? 28 : 32
        implicitWidth: Math.max(120, contentItem.implicitWidth + 24)
        onClicked: root.setView(view)

        background: Rectangle {
            radius: 3
            color: tab.selected ? withAlpha(tab.accent, 0.24) : (tab.hovered ? withAlpha(tab.accent, 0.14) : root.theme.surface)
            border.width: 1
            border.color: tab.selected ? withAlpha(tab.accent, 0.70) : withAlpha(tab.accent, 0.24)

            Behavior on color {
                ColorAnimation { duration: 110 }
            }

            Behavior on border.color {
                ColorAnimation { duration: 110 }
            }
        }

        // Same split as CodexButton: the glyph is drawn in the icon font, the
        // label in the text font, so neither depends on fontconfig's fallback.
        contentItem: Item {
            implicitWidth: tabRow.implicitWidth
            implicitHeight: tabRow.implicitHeight

            RowLayout {
                id: tabRow
                anchors.centerIn: parent
                spacing: 6

                Text {
                    visible: !!tab.glyph
                    text: tab.glyph
                    color: tab.selected ? root.theme.text : root.theme.textBody
                    font.family: root.iconFont
                    font.pixelSize: tab.font.pixelSize
                }

                Label {
                    text: tab.text
                    color: tab.selected ? root.theme.text : root.theme.textBody
                    font.family: root.textFont
                    font.pixelSize: tab.font.pixelSize
                    font.bold: tab.font.bold
                }
            }
        }
    }

    component BadgePill: Rectangle {
        id: pill
        property string text: ""
        property string icon: ""
        property color accent: root.theme.textMuted
        property color foreground: root.theme.textSoft
        property int minimumWidth: 0
        property int maximumWidth: 220

        radius: 3
        implicitHeight: 18
        implicitWidth: Math.min(maximumWidth, Math.max(minimumWidth, contentRow.implicitWidth + 10))
        color: "transparent"
        clip: true

        RowLayout {
            id: contentRow
            anchors.fill: parent
            anchors.leftMargin: 5
            anchors.rightMargin: 5
            spacing: 4

            // Tone dot: the accent reads at a glance without a tinted fill.
            Rectangle {
                visible: pill.icon.length === 0
                Layout.preferredWidth: 6
                Layout.preferredHeight: 6
                radius: 3
                color: pill.accent
            }

            Text {
                visible: pill.icon.length > 0
                text: pill.icon
                color: pill.foreground
                font.family: root.iconFont
                font.pixelSize: 10
                renderType: Text.NativeRendering
            }

            Label {
                Layout.fillWidth: true
                text: pill.text
                color: pill.foreground
                font.family: root.textFont
                font.pixelSize: 9
                elide: Text.ElideRight
            }
        }
    }

    component SectionHeader: RowLayout {
        id: sectionHeader
        property string text: ""
        property string icon: ""
        property color accent: root.theme.textDim

        spacing: 6

        Text {
            text: sectionHeader.icon
            color: sectionHeader.accent
            font.family: root.iconFont
            font.pixelSize: 12
            visible: text.length > 0
        }

        Label {
            text: sectionHeader.text
            color: sectionHeader.accent
            font.family: root.textFont
            font.pixelSize: 10
            font.bold: true
        }
    }

    component MetricBar: Item {
        id: metricBar
        property real usedPercent: 0
        property color accent: root.theme.good

        implicitHeight: 6
        implicitWidth: 220

        Rectangle {
            anchors.fill: parent
            radius: 0
            color: root.theme.surfaceHi
            border.width: 1
            border.color: withAlpha(metricBar.accent, 0.18)
        }

        Rectangle {
            width: Math.max(0, Math.min(metricBar.width, metricBar.width * (metricBar.usedPercent / 100.0)))
            height: metricBar.height
            radius: 0
            Behavior on width {
                NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
            }

            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.lighter(metricBar.accent, 1.22) }
                GradientStop { position: 0.55; color: metricBar.accent }
                GradientStop { position: 1.0; color: Qt.darker(metricBar.accent, 1.12) }
            }
        }
    }

    component CardFrame: Rectangle {
        id: card
        property color accent: root.theme.good
        radius: 4
        color: root.theme.surfaceHi
        border.width: 1
        border.color: withAlpha(accent, 0.28)
        clip: true
    }

    // Trailing peak marker for rows whose right end is the card's content edge.
    // The slot is explicit so the glyph keeps its place whatever the row's text
    // length is, and the right inset keeps it clear of that edge — which is also
    // where the detail view's scrollbar overlays the card's padding. The width is
    // the glyph advance plus room for the tooltip hover area.
    component PeakGlyph: Text {
        property var peak: null
        visible: !!peak
        Layout.preferredWidth: 14
        Layout.rightMargin: 6
        Layout.alignment: Qt.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        text: root.peakBadgeIcon(peak)
        color: root.peakBadgeAccent(peak)
        font.family: root.iconFont
        font.pixelSize: 11

        MouseArea {
            id: peakGlyphHover
            anchors.fill: parent
            hoverEnabled: true
        }

        ToolTip.visible: peakGlyphHover.containsMouse
        ToolTip.delay: 150
        ToolTip.text: root.peakBadgeDetail(peak)
    }

    component UsageHeatmap: CardFrame {
        id: usageHeatmap
        property var heatmapData: null
        property string panelTitle: "Token usage"

        visible: !!usageHeatmap.heatmapData
        Layout.fillWidth: true
        Layout.preferredHeight: heatmapColumn.implicitHeight + 28
        color: root.theme.surface

        ColumnLayout {
            id: heatmapColumn
            anchors.fill: parent
            anchors.margins: 14
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: root.glyphs.cost
                    color: usageHeatmap.accent
                    font.family: root.iconFont
                    font.pixelSize: 13
                }

                Label {
                    text: usageHeatmap.panelTitle + "  " + (usageHeatmap.heatmapData ? usageHeatmap.heatmapData.totalText : "")
                    color: root.theme.text
                    font.family: root.textFont
                    font.pixelSize: 11
                    font.bold: true
                }

                Item { Layout.fillWidth: true }

                Label {
                    Layout.fillWidth: true
                    text: root.heatmapStatsLine(usageHeatmap.heatmapData)
                    color: root.theme.textDim
                    font.family: root.textFont
                    font.pixelSize: 10
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 16

                Flickable {
                    Layout.fillWidth: true
                    Layout.preferredHeight: usageHeatmapGrid.implicitHeight
                    contentWidth: usageHeatmapGrid.implicitWidth
                    contentHeight: usageHeatmapGrid.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: usageHeatmapGrid
                        spacing: 3

                        Repeater {
                            model: usageHeatmap.heatmapData ? usageHeatmap.heatmapData.rows : []

                            delegate: Row {
                                required property var modelData
                                spacing: 3

                                Repeater {
                                    model: modelData.cells || []

                                    delegate: Rectangle {
                                        id: heatCell
                                        required property var modelData
                                        width: 12
                                        height: 12
                                        radius: 0
                                        color: root.heatmapColor(modelData)
                                        scale: heatCellHover.containsMouse ? 1.3 : 1.0
                                        z: heatCellHover.containsMouse ? 3 : 0

                                        Behavior on scale {
                                            NumberAnimation { duration: 110 }
                                        }

                                        MouseArea {
                                            id: heatCellHover
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            enabled: heatCell.modelData.tooltipText.length > 0
                                        }

                                        ToolTip.visible: heatCellHover.containsMouse
                                        ToolTip.delay: 150
                                        ToolTip.text: heatCell.modelData.tooltipText
                                    }
                                }
                            }
                        }
                    }
                }

                ColumnLayout {
                    spacing: 4

                    Label {
                        text: "more"
                        color: root.theme.textMuted
                        font.family: root.textFont
                        font.pixelSize: 9
                    }

                    Repeater {
                        model: [root.theme.good, root.theme.goodMid, root.theme.goodDeep, root.theme.goodBg, root.theme.border, root.theme.surface]

                        delegate: Rectangle {
                            required property string modelData
                            width: 9
                            height: 9
                            radius: 0
                            color: modelData
                        }
                    }

                    Label {
                        text: "less"
                        color: root.theme.textMuted
                        font.family: root.textFont
                        font.pixelSize: 9
                    }
                }
            }
        }
    }

    component HistoryDayTile: CardFrame {
        id: dayTile
        property var itemData: ({})
        Layout.preferredHeight: 86
        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
        color: root.theme.surface

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Label {
                    Layout.fillWidth: true
                    text: itemData.label || itemData.date || "--"
                    color: root.theme.text
                    font.family: root.textFont
                    font.pixelSize: 11
                    font.bold: true
                }

                Label {
                    text: itemData.quotaText || "No quota"
                    color: dayTile.accent
                    font.family: root.textFont
                    font.pixelSize: 10
                    font.bold: true
                }
            }

            MetricBar {
                Layout.fillWidth: true
                usedPercent: itemData.barPercent || 0
                accent: dayTile.accent
            }

            Label {
                Layout.fillWidth: true
                text: itemData.detail || "No local token summary"
                color: root.theme.textDim
                font.family: root.textFont
                font.pixelSize: 10
                elide: Text.ElideRight
            }
        }
    }

    component ProviderIconBubble: Rectangle {
        id: bubble
        property string icon: ""
        property color accent: root.theme.good

        width: 28
        height: 28
        radius: 0
        color: withAlpha(accent, 0.16)
        border.width: 1
        border.color: withAlpha(accent, 0.34)

        Text {
            anchors.centerIn: parent
            text: bubble.icon
            color: bubble.accent
            font.family: root.iconFont
            font.pixelSize: 15
        }
    }

    component DetailTile: CardFrame {
        id: tile
        property var itemData: ({})
        property var liveData: itemData.scheduleId ? root.peakCardLive(itemData.scheduleId) : null
        Layout.fillWidth: true
        Layout.preferredHeight: 72
        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
        color: root.theme.surface

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 4

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                    text: itemData.icon || ""
                    color: tile.accent
                    font.family: root.iconFont
                    font.pixelSize: 13
                }

                Label {
                    Layout.fillWidth: true
                    text: itemData.label || ""
                    color: root.theme.textBody
                    font.family: root.textFont
                    font.pixelSize: 10
                    font.bold: true
                }
            }

            Label {
                Layout.fillWidth: true
                text: tile.liveData ? tile.liveData.value : (itemData.value || "--")
                color: root.theme.text
                font.family: root.textFont
                font.pixelSize: 15
                font.bold: true
                elide: Text.ElideRight
            }

            Label {
                Layout.fillWidth: true
                text: tile.liveData ? tile.liveData.detail : (itemData.detail || "")
                color: root.theme.textDim
                font.family: root.textFont
                font.pixelSize: 10
                elide: Text.ElideRight
                visible: !!(tile.liveData ? tile.liveData.detail : itemData.detail)
            }
        }
    }

    component ProviderRow: CardFrame {
        id: providerRow
        property var providerData: ({})
        implicitHeight: 78
        accent: statusColor(providerData)
        color: providerData.id === root.focusProviderId ? root.theme.surface : (railHover.containsMouse ? root.theme.surfaceHi : root.theme.surface)

        Behavior on color {
            ColorAnimation { duration: 110 }
        }

        MouseArea {
            id: railHover
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            hoverEnabled: true
            onClicked: {
                root.setFocus(providerRow.providerData.id)
                root.setView("detail")
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: 11
            spacing: 10

            ProviderIconBubble {
                icon: providerRow.providerData.icon || ""
                accent: statusColor(providerRow.providerData)
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 3

                RowLayout {
                    Layout.fillWidth: true
                    Layout.minimumHeight: 20

                    Label {
                        text: providerRow.providerData.label
                        color: root.theme.text
                        font.family: root.textFont
                        font.pixelSize: 12
                        font.bold: true
                    }

                    Item { Layout.fillWidth: true }

                    BadgePill {
                        visible: providerRow.providerData.display
                        text: "display"
                        icon: root.glyphs.display
                        accent: statusColor(providerRow.providerData)
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: providerRow.providerData.chipText || "--"
                    color: statusColor(providerRow.providerData)
                    font.family: root.textFont
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        BadgePill {
                            text: providerRow.providerData.enabled ? "active" : "off"
                            icon: providerRow.providerData.enabled ? root.glyphs.status : root.glyphs.close
                            accent: providerRow.providerData.enabled ? root.theme.good : root.theme.textMuted
                            minimumWidth: 68
                        }

                        BadgePill {
                            text: providerRow.providerData.visible ? "shown" : "hidden"
                            icon: providerRow.providerData.visible ? root.glyphs.shown : root.glyphs.hidden
                            accent: providerRow.providerData.visible ? root.theme.info : root.theme.textMuted
                            minimumWidth: 72
                        }
                    }
                }
            }
        }

    onProviderViewsChanged: {
        if (!findProvider(focusProviderId)) {
            syncFocus()
        }
    }

    PanelWindow {
        id: panelWindow
        visible: uiAdapter.open
        screen: Quickshell.screens.length ? Quickshell.screens[0] : null
        color: "transparent"
        // Mac-bar behavior: no focus grab, no backdrop. The input mask is
        // bound to the modal frame, so clicks outside it reach the desktop.
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        mask: Region { item: modalFrame; intersection: Intersection.Intersect }
        aboveWindows: true
        exclusionMode: ExclusionMode.Ignore
        property int verticalMargin: root.dense ? 10 : 18
        implicitWidth: screen ? screen.width : 960
        implicitHeight: screen ? screen.height : 760

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        margins {
            top: 0
            bottom: 0
            left: 0
            right: 0
        }

        onVisibleChanged: {
            if (visible) {
                root.syncFocus()
                modalFade.restart()
            }
        }

        NumberAnimation {
            id: modalFade
            target: modalFrame
            property: "opacity"
            from: 0
            to: 1
            duration: 150
            easing.type: Easing.OutCubic
        }

        Item {
            anchors.fill: parent

            Rectangle {
                anchors.centerIn: parent
                width: modalFrame.width + 10
                height: modalFrame.height + 10
                radius: 0
                color: Qt.rgba(0, 0, 0, 0.22)
            }

            Rectangle {
                anchors.centerIn: parent
                width: modalFrame.width + 4
                height: modalFrame.height + 4
                radius: 0
                color: Qt.rgba(0, 0, 0, 0.34)
            }

            FocusScope {
                id: modalFrame
                anchors.centerIn: parent
                width: Math.min(960, Math.max(320, panelWindow.width - (root.dense ? 24 : 36)))
                height: Math.min(panelWindow.height - 12, Math.max(420, panelWindow.height - (panelWindow.verticalMargin * 2)))

                Keys.onEscapePressed: root.closePanel()

                CardFrame {
                    anchors.fill: parent
                    accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                    color: root.theme.bg

                MouseArea {
                    anchors.fill: parent
                }

                Rectangle {
                    anchors.fill: parent
                    radius: 0
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: root.theme.surfaceHi }
                        GradientStop { position: 1.0; color: root.theme.bgDeep }
                    }
                    opacity: 1.0
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: root.dense ? 12 : 18
                    spacing: root.dense ? 8 : 12

                    CardFrame {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.dense ? 62 : 78
                        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: root.dense ? 8 : 14
                            spacing: 12

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4

                                RowLayout {
                                    spacing: 8

                                    ProviderIconBubble {
                                        icon: focusProvider() ? focusProvider().icon : root.glyphs.provider
                                        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                    }

                                    ColumnLayout {
                                        spacing: 2

                                        Label {
                                            text: viewData.summary && viewData.summary.displayLabel ? ("TokenMaxx / " + viewData.summary.displayLabel) : "TokenMaxx"
                                            color: root.theme.text
                                            font.family: root.textFont
                                            font.pixelSize: root.dense ? 15 : 18
                                            font.bold: true
                                        }

                                        Label {
                                            text: viewData.summary && viewData.summary.displayText ? viewData.summary.displayText : "Waiting for provider cache"
                                            color: focusProvider() ? statusColor(focusProvider()) : root.theme.textSoft
                                            font.family: root.textFont
                                            font.pixelSize: 12
                                        }
                                    }
                                }

                                Label {
                                    text: (viewData.summary.updatedText || "Waiting for cached data") + "  •  " + (viewData.summary.activeCount || 0) + " active  •  " + (viewData.summary.visibleCount || 0) + " visible"
                                    color: root.theme.textDim
                                    font.family: root.textFont
                                    font.pixelSize: 10
                                }
                            }

                            RowLayout {
                                Layout.alignment: Qt.AlignRight
                                spacing: 6

                                BadgePill {
                                    text: viewData.summary.modeLabel || "Highest usage"
                                    icon: root.glyphs.status
                                    accent: root.theme.good
                                    maximumWidth: 126
                                }

                                BadgePill {
                                    text: viewData.summary.showUsedLabel || "Remaining"
                                    icon: root.glyphs.meter
                                    accent: root.theme.info
                                    maximumWidth: 106
                                }

                                BadgePill {
                                    text: viewData.summary.metricModeLabel || "both"
                                    icon: root.glyphs.overview
                                    accent: root.theme.warn
                                    maximumWidth: 78
                                }

                                BadgePill {
                                    text: viewData.summary.refreshModeLabel || "120s refresh"
                                    icon: root.glyphs.refresh
                                    accent: root.theme.good
                                    maximumWidth: 124
                                }

                                BadgePill {
                                    text: viewData.summary.notificationsLabel || "Notify off"
                                    icon: root.glyphs.bell
                                    accent: viewData.summary.notificationsLabel === "Notify on" ? root.theme.info : root.theme.textMuted
                                    maximumWidth: 108
                                }

                                CodexButton {
                                    text: ""
                                    glyph: root.glyphs.refresh
                                    accent: root.theme.good
                                    compact: true
                                    minimumWidth: 34
                                    onClicked: root.runTokenMaxx(["refresh"])
                                }

                                CodexButton {
                                    text: ""
                                    glyph: root.glyphs.close
                                    accent: root.theme.bad
                                    compact: true
                                    minimumWidth: 34
                                    onClicked: root.closePanel()
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        ViewTab {
                            text: "Overview"
                            view: "overview"
                            glyph: root.glyphs.overview
                            accent: root.theme.good
                        }

                        ViewTab {
                            text: "Provider Detail"
                            view: "detail"
                            glyph: root.glyphs.provider
                            accent: focusProvider() ? statusColor(focusProvider()) : root.theme.info
                        }

                        ViewTab {
                            text: "History"
                            view: "history"
                            glyph: root.glyphs.history
                            accent: root.theme.warn
                        }

                        ViewTab {
                            text: "Settings"
                            view: "settings"
                            glyph: root.glyphs.settings
                            accent: root.theme.textBody
                        }

                        Item { Layout.fillWidth: true }

                        BadgePill {
                            text: focusProvider() ? focusProvider().status : "loading"
                            icon: root.glyphs.status
                            accent: focusProvider() ? statusColor(focusProvider()) : root.theme.textMuted
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.activeView === "overview" || root.activeView === "detail"
                        spacing: 12

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 12

                            CardFrame {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                visible: root.activeView === "overview"
                                accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good

                                ScrollView {
                                    id: overviewScroll
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    clip: true
                                    contentWidth: availableWidth
                                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                    ScrollBar.vertical.policy: ScrollBar.AsNeeded

                                    Item {
                                        width: overviewScroll.availableWidth
                                        height: overviewContent.implicitHeight + 24

                                        ColumnLayout {
                                            id: overviewContent
                                            anchors.top: parent.top
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.margins: root.dense ? 10 : 12
                                            spacing: root.dense ? 8 : 10

                                    RowLayout {
                                        spacing: 8

                                        Text {
                                            text: root.glyphs.overview
                                            color: root.theme.info
                                            font.family: root.iconFont
                                            font.pixelSize: 13
                                        }

                                        Label {
                                            text: "Overview"
                                            color: root.theme.text
                                            font.family: root.textFont
                                            font.pixelSize: 12
                                            font.bold: true
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        BadgePill {
                                            text: viewData.summary.updatedText || "Waiting for cached data"
                                            icon: root.glyphs.refresh
                                            accent: viewData.summary.stale ? root.theme.warn : root.theme.good
                                        }

                                        BadgePill {
                                            text: (viewData.summary.activeCount || 0) + " active"
                                            icon: root.glyphs.status
                                            accent: root.theme.good
                                        }

                                        BadgePill {
                                            text: viewData.summary.statusLabel || "Status off"
                                            icon: root.glyphs.status
                                            accent: viewData.summary.statusLabel === "Status on" ? root.theme.info : root.theme.textMuted
                                        }

                                        BadgePill {
                                            text: viewData.summary.refreshModeLabel || "120s refresh"
                                            icon: root.glyphs.refresh
                                            accent: root.theme.warn
                                        }

                                        BadgePill {
                                            text: viewData.summary.privacyLabel || "Privacy off"
                                            icon: root.glyphs.privacy
                                            accent: viewData.summary.privacyLabel === "Privacy on" ? root.theme.warn : root.theme.textMuted
                                        }

                                        Item { Layout.fillWidth: true }
                                    }

                                    UsageHeatmap {
                                        heatmapData: viewData.heatmap && viewData.heatmap.available ? viewData.heatmap : null
                                        panelTitle: "All providers"
                                        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        Repeater {
                                            model: root.overviewProviders()

                                            delegate: CardFrame {
                                                required property var modelData
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: root.dense ? 102 : 118
                                                accent: statusColor(modelData)
                                                color: modelData.id === root.focusProviderId ? root.theme.surface : (cardHover.containsMouse ? root.theme.surfaceHi : root.theme.surface)

                                                Behavior on color {
                                                    ColorAnimation { duration: 110 }
                                                }

                                                MouseArea {
                                                    id: cardHover
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    hoverEnabled: true
                                                    onClicked: {
                                                        root.setFocus(modelData.id)
                                                        root.setView("detail")
                                                    }
                                                }

                                                ColumnLayout {
                                                    anchors.fill: parent
                                                    anchors.margins: 10
                                                    spacing: 4

                                                    RowLayout {
                                                        Layout.fillWidth: true
                                                        Layout.minimumHeight: 20
                                                        spacing: 8

                                                        ProviderIconBubble {
                                                            icon: modelData.icon || ""
                                                            accent: statusColor(modelData)
                                                        }

                                                        ColumnLayout {
                                                            Layout.fillWidth: true
                                                            spacing: 2

                                                            RowLayout {
                                                                Layout.fillWidth: true
                                                                spacing: 4

                                                                Label {
                                                                    Layout.fillWidth: true
                                                                    Layout.minimumWidth: 0
                                                                    text: modelData.label
                                                                    color: root.theme.text
                                                                    font.family: root.textFont
                                                                    font.pixelSize: 11
                                                                    font.bold: true
                                                                    elide: Text.ElideRight
                                                                }

                                                                PeakGlyph {
                                                                    peak: modelData.peak
                                                                }
                                                            }

                                                            Label {
                                                                Layout.fillWidth: true
                                                                text: modelData.quotaSummaryText || modelData.chipText || "--"
                                                                color: statusColor(modelData)
                                                                font.family: root.textFont
                                                                font.pixelSize: 11
                                                                font.bold: true
                                                                elide: Text.ElideRight
                                                            }
                                                        }

                                                        Item { Layout.fillWidth: true }

                                                        BadgePill {
                                                            visible: modelData.display
                                                            icon: root.glyphs.display
                                                            accent: statusColor(modelData)
                                                            maximumWidth: 30
                                                        }
                                                    }

                                                    MetricBar {
                                                        Layout.fillWidth: true
                                                        usedPercent: modelData.dominantMetric ? modelData.dominantMetric.usedPercent : 0
                                                        accent: statusColor(modelData)
                                                        visible: !!modelData.dominantMetric
                                                    }

                                                    Label {
                                                        Layout.fillWidth: true
                                                        text: modelData.serviceStatusText || "Status unknown"
                                                        color: statusColor(modelData)
                                                        font.family: root.textFont
                                                        font.pixelSize: 10
                                                        elide: Text.ElideRight
                                                    }

                                                    Label {
                                                        Layout.fillWidth: true
                                                        text: modelData.localUsageText || "Local usage pending"
                                                        color: root.theme.textDim
                                                        font.family: root.textFont
                                                        font.pixelSize: 10
                                                        elide: Text.ElideRight
                                                    }

                                                    Label {
                                                        Layout.fillWidth: true
                                                        text: modelData.freshnessText || "Waiting for cached data"
                                                        color: root.theme.textDim
                                                        font.family: root.textFont
                                                        font.pixelSize: 10
                                                        elide: Text.ElideRight
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    Item { Layout.fillHeight: true }

                                    CardFrame {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 96
                                        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                        color: root.theme.surface

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.margins: 12
                                            spacing: 12

                                            ProviderIconBubble {
                                                icon: displayProvider() ? displayProvider().icon : root.glyphs.provider
                                                accent: displayProvider() ? statusColor(displayProvider()) : root.theme.good
                                            }

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 4

                                                Label {
                                                    text: displayProvider() ? ("Active display: " + displayProvider().label) : "Active display pending"
                                                    color: root.theme.text
                                                    font.family: root.textFont
                                                    font.pixelSize: 15
                                                    font.bold: true
                                                }

                                                Label {
                                                    Layout.fillWidth: true
                                                    text: displayProvider() ? root.compactJoin([displayProvider().chipText, displayProvider().serviceStatusText, displayProvider().historySummary]) : "Waiting for cached data"
                                                    color: root.theme.textBody
                                                    font.family: root.textFont
                                                    font.pixelSize: 11
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            CodexButton {
                                                text: "Refresh"
                                                glyph: root.glyphs.refresh
                                                accent: root.theme.good
                                                compact: true
                                                onClicked: root.runTokenMaxx(["refresh"])
                                            }
                                        }
                                    }
                                        }
                                    }
                                }
                            }

                            CardFrame {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                visible: root.activeView === "detail"
                                accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good

                                ScrollView {
                                    id: detailScroll
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    clip: true
                                    contentWidth: availableWidth
                                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                    ScrollBar.vertical.policy: ScrollBar.AsNeeded

                                    Item {
                                        width: detailScroll.availableWidth
                                        height: detailContent.implicitHeight + 24

                                        ColumnLayout {
                                            id: detailContent
                                            anchors.top: parent.top
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.margins: 12
                                            spacing: 12

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10

                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 4

                                                RowLayout {
                                                    spacing: 8

                                                    ProviderIconBubble {
                                                        icon: focusProvider() ? focusProvider().icon : ""
                                                        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                                    }

                                                    ColumnLayout {
                                                        spacing: 2

                                                        Label {
                                                            text: focusProvider() ? focusProvider().label : "No provider selected"
                                                            color: root.theme.text
                                                            font.family: root.textFont
                                                            font.pixelSize: 18
                                                            font.bold: true
                                                        }

                                                        Label {
                                                            text: focusProvider() ? focusProvider().identityText : "Waiting for provider data"
                                                            color: root.theme.textBody
                                                            font.family: root.textFont
                                                            font.pixelSize: 11
                                                        }

                                                        Label {
                                                            text: focusProvider() ? ((focusProvider().serviceStatusText || "Status unknown") + (focusProvider().localUsageText ? ("  •  " + focusProvider().localUsageText) : "")) : ""
                                                            color: focusProvider() ? statusColor(focusProvider()) : root.theme.textDim
                                                            font.family: root.textFont
                                                            font.pixelSize: 10
                                                            elide: Text.ElideRight
                                                        }
                                                    }
                                                }
                                            }

                                            Repeater {
                                                model: focusProvider() ? focusProvider().badges : []

                                                delegate: BadgePill {
                                                    required property string modelData
                                                    text: modelData
                                                    icon: modelData === "display" ? root.glyphs.display : (modelData === "pinned" ? root.glyphs.pinned : (modelData === "hidden" ? root.glyphs.hidden : (modelData === "overview" ? root.glyphs.overview : "")))
                                                    accent: statusColor(focusProvider())
                                                }
                                            }
                                        }

                                        CardFrame {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 132
                                            accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                            color: root.theme.surfaceHi

                                            ColumnLayout {
                                                anchors.fill: parent
                                                anchors.margins: 14
                                                spacing: 8

                                                RowLayout {
                                                    spacing: 8

                                                    Text {
                                                        text: focusProvider() && focusProvider().hero ? focusProvider().hero.icon : ""
                                                        color: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                                        font.family: root.iconFont
                                                        font.pixelSize: 13
                                                    }

                                                    Label {
                                                        text: focusProvider() && focusProvider().hero ? focusProvider().hero.title : "Status"
                                                        color: root.theme.textBody
                                                        font.family: root.textFont
                                                        font.pixelSize: 11
                                                        font.bold: true
                                                    }
                                                }

                                                RowLayout {
                                                    Layout.fillWidth: true

                                                    Label {
                                                        text: focusProvider() && focusProvider().hero ? focusProvider().hero.value : (focusProvider() ? focusProvider().chipText : "--")
                                                        color: focusProvider() ? statusColor(focusProvider()) : root.theme.textSoft
                                                        font.family: root.textFont
                                                        font.pixelSize: 24
                                                        font.bold: true
                                                    }

                                                    Item { Layout.fillWidth: true }

                                                    BadgePill {
                                                        visible: !!(focusProvider() && focusProvider().peak)
                                                        text: root.peakBadgeLabel(focusProvider() ? focusProvider().peak : null)
                                                        icon: root.peakBadgeIcon(focusProvider() ? focusProvider().peak : null)
                                                        accent: root.peakBadgeAccent(focusProvider() ? focusProvider().peak : null)
                                                        maximumWidth: 100
                                                    }

                                                    BadgePill {
                                                        visible: !!(focusProvider() && focusProvider().hero && focusProvider().hero.supporting)
                                                        text: focusProvider() && focusProvider().hero ? focusProvider().hero.supporting : ""
                                                        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                                    }
                                                }

                                                MetricBar {
                                                    Layout.fillWidth: true
                                                    visible: !!(focusProvider() && focusProvider().hero && focusProvider().hero.progressVisible)
                                                    usedPercent: focusProvider() && focusProvider().hero ? focusProvider().hero.progressPercent : 0
                                                    accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                                }

                                                Label {
                                                    text: focusProvider() && focusProvider().hero && focusProvider().hero.detail ? focusProvider().hero.detail : "No additional quota detail"
                                                    color: root.theme.textBody
                                                    font.family: root.textFont
                                                    font.pixelSize: 10
                                                    wrapMode: Text.Wrap
                                                    Layout.fillWidth: true
                                                }
                                            }
                                        }

                                        GridLayout {
                                            Layout.fillWidth: true
                                            columns: 2
                                            rowSpacing: 8
                                            columnSpacing: 8

                                            Repeater {
                                                model: focusProvider() ? focusProvider().detailCards : []

                                                delegate: DetailTile {
                                                    required property var modelData
                                                    itemData: modelData
                                                }
                                            }
                                        }

                                        CardFrame {
                                            visible: !!(focusProvider() && focusProvider().localUsageModels && focusProvider().localUsageModels.length)
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: geminiUsageColumn.implicitHeight + 24
                                            accent: focusProvider() ? statusColor(focusProvider()) : root.theme.info
                                            color: root.theme.surfaceDeep

                                            ColumnLayout {
                                                id: geminiUsageColumn
                                                anchors.fill: parent
                                                anchors.margins: 12
                                                spacing: 8

                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 8

                                                    Text {
                                                        text: root.glyphs.cost
                                                        color: focusProvider() ? statusColor(focusProvider()) : root.theme.info
                                                        font.family: root.iconFont
                                                        font.pixelSize: 13
                                                    }

                                                    Label {
                                                        Layout.fillWidth: true
                                                        text: "Model local usage"
                                                        color: root.theme.text
                                                        font.family: root.textFont
                                                        font.pixelSize: 11
                                                        font.bold: true
                                                    }
                                                }

                                                Label {
                                                    Layout.fillWidth: true
                                                    visible: !!focusProvider() && !!focusProvider().localUsageSourcesText
                                                    text: focusProvider() && focusProvider().localUsageSourcesText ? focusProvider().localUsageSourcesText : ""
                                                    color: root.theme.textDim
                                                    font.family: root.textFont
                                                    font.pixelSize: 9
                                                    elide: Text.ElideRight
                                                }

                                                Repeater {
                                                    model: focusProvider() && focusProvider().localUsageModels ? focusProvider().localUsageModels : []

                                                    delegate: RowLayout {
                                                        required property var modelData
                                                        Layout.fillWidth: true
                                                        spacing: 8

                                                        Label {
                                                            Layout.fillWidth: true
                                                            Layout.minimumWidth: 0
                                                            text: modelData.label || "--"
                                                            color: root.theme.textBody
                                                            font.family: root.textFont
                                                            font.pixelSize: 10
                                                            elide: Text.ElideRight
                                                        }

                                                        Label {
                                                            text: modelData.tokensText || "--"
                                                            color: focusProvider() ? statusColor(focusProvider()) : root.theme.info
                                                            font.family: root.textFont
                                                            font.pixelSize: 10
                                                            font.bold: true
                                                        }

                                                        Label {
                                                            text: modelData.recordsText || ""
                                                            color: root.theme.textDim
                                                            font.family: root.textFont
                                                            font.pixelSize: 10
                                                        }

                                                        PeakGlyph {
                                                            peak: modelData.peak
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        CardFrame {
                                            visible: !!(focusProvider() && (focusProvider().error || focusProvider().notes.length || focusProvider().incident))
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: notesColumn.implicitHeight + 24
                                            accent: focusProvider() ? statusColor(focusProvider()) : root.theme.bad
                                            color: root.theme.surfaceDeep

                                            ColumnLayout {
                                                id: notesColumn
                                                anchors.fill: parent
                                                anchors.margins: 12
                                                spacing: 6

                                                RowLayout {
                                                    spacing: 8

                                                    Text {
                                                        text: root.glyphs.alert
                                                        color: focusProvider() ? statusColor(focusProvider()) : root.theme.bad
                                                        font.family: root.iconFont
                                                        font.pixelSize: 13
                                                    }

                                                    Label {
                                                        text: "Provider notes"
                                                        color: root.theme.text
                                                        font.family: root.textFont
                                                        font.pixelSize: 11
                                                        font.bold: true
                                                    }
                                                }

                                                Label {
                                                    visible: !!(focusProvider() && focusProvider().error)
                                                    text: focusProvider() ? focusProvider().error : ""
                                                    color: root.theme.badSoft
                                                    font.family: root.textFont
                                                    font.pixelSize: 11
                                                    wrapMode: Text.Wrap
                                                    Layout.fillWidth: true
                                                }

                                                Label {
                                                    visible: !!(focusProvider() && focusProvider().incident)
                                                    text: focusProvider() ? focusProvider().incident : ""
                                                    color: root.theme.info
                                                    font.family: root.textFont
                                                    font.pixelSize: 11
                                                    wrapMode: Text.Wrap
                                                    Layout.fillWidth: true
                                                }

                                                Repeater {
                                                    model: focusProvider() ? focusProvider().notes : []

                                                    delegate: RowLayout {
                                                        required property string modelData
                                                        Layout.fillWidth: true
                                                        spacing: 6

                                                        Text {
                                                            text: root.glyphs.note
                                                            color: root.theme.textSoft
                                                            font.family: root.iconFont
                                                            font.pixelSize: 10
                                                            Layout.alignment: Qt.AlignTop
                                                        }

                                                        Label {
                                                            text: modelData
                                                            color: root.theme.textSoft
                                                            font.family: root.textFont
                                                            font.pixelSize: 10
                                                            wrapMode: Text.Wrap
                                                            Layout.fillWidth: true
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        Label {
                                            text: focusProvider() ? ("Source " + focusProvider().source + "  •  " + focusProvider().freshnessText) : ""
                                            color: root.theme.textDim
                                            font.family: root.textFont
                                            font.pixelSize: 10
                                        }
                                        }
                                    }
                                }
                            }
                        }

                        CardFrame {
                            Layout.preferredWidth: 260
                            Layout.fillHeight: true
                            accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 12

                                RowLayout {
                                    spacing: 8

                                    Text {
                                        text: root.glyphs.provider
                                        color: root.theme.text
                                        font.family: root.iconFont
                                        font.pixelSize: 12
                                    }

                                    Label {
                                        text: "Providers"
                                        color: root.theme.text
                                        font.family: root.textFont
                                        font.pixelSize: 12
                                        font.bold: true
                                    }
                                }

                                ScrollView {
                                    id: providerScroll
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    contentWidth: availableWidth
                                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                    ScrollBar.vertical.policy: ScrollBar.AsNeeded

                                    Column {
                                        id: providerList
                                        width: providerScroll.availableWidth
                                        spacing: 10

                                        Repeater {
                                            model: providerViews

                                            delegate: ProviderRow {
                                                width: providerList.width
                                                providerData: modelData
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    CardFrame {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.activeView === "history"
                        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.warn

                        ColumnLayout {
                            id: historyColumn
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 12

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10

                                ProviderIconBubble {
                                    icon: focusProvider() ? focusProvider().icon : root.glyphs.history
                                    accent: focusProvider() ? statusColor(focusProvider()) : root.theme.warn
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 3

                                    Label {
                                        text: focusProvider() ? (focusProvider().label + " history") : "History"
                                        color: root.theme.text
                                        font.family: root.textFont
                                        font.pixelSize: 18
                                        font.bold: true
                                    }

                                    Label {
                                        Layout.fillWidth: true
                                        text: focusProvider() ? (focusProvider().historySummary || "No retained history") : "Waiting for provider data"
                                        color: root.theme.textBody
                                        font.family: root.textFont
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }
                                }

                                Repeater {
                                    model: providerViews

                                    delegate: CodexButton {
                                        required property var modelData
                                        text: modelData.shortLabel
                                        glyph: modelData.icon
                                        accent: modelData.id === root.focusProviderId ? statusColor(modelData) : root.theme.textMuted
                                        compact: true
                                        onClicked: root.setFocus(modelData.id)
                                    }
                                }
                            }

                            ScrollView {
                                id: historyScroll
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                contentWidth: availableWidth
                                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                                ScrollBar.vertical.policy: ScrollBar.AsNeeded

                                Item {
                                    width: historyScroll.availableWidth
                                    height: historyContent.implicitHeight + 12

                                    ColumnLayout {
                                        id: historyContent
                                        anchors.top: parent.top
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        spacing: 12

                                        UsageHeatmap {
                                            id: heatmapCard
                                            heatmapData: historyHeatmap()
                                            accent: focusProvider() ? statusColor(focusProvider()) : root.theme.warn
                                        }

                                        GridLayout {
                                            id: historyGrid
                                            Layout.fillWidth: true
                                            columns: 4
                                            columnSpacing: 10
                                            rowSpacing: 10
                                            visible: root.providerHistory().length > 0

                                            Repeater {
                                                model: root.providerHistory()

                                                delegate: HistoryDayTile {
                                                    required property var modelData
                                                    itemData: modelData
                                                    Layout.preferredWidth: Math.max(0, (historyContent.width - (historyGrid.columns - 1) * historyGrid.columnSpacing) / historyGrid.columns)
                                                }
                                            }
                                        }

                                        CardFrame {
                                            id: historyEmpty
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: Math.max(180, historyEmptyColumn.implicitHeight + 40)
                                            visible: root.providerHistory().length === 0
                                            accent: root.theme.textMuted
                                            color: root.theme.surface

                                            ColumnLayout {
                                                id: historyEmptyColumn
                                                anchors.centerIn: parent
                                                spacing: 10

                                                Text {
                                                    Layout.alignment: Qt.AlignHCenter
                                                    text: root.glyphs.history
                                                    color: root.theme.textMuted
                                                    font.family: root.iconFont
                                                    font.pixelSize: 30
                                                }

                                                Label {
                                                    Layout.alignment: Qt.AlignHCenter
                                                    text: "No retained history yet"
                                                    color: root.theme.text
                                                    font.family: root.textFont
                                                    font.pixelSize: 16
                                                    font.bold: true
                                                }

                                                Label {
                                                    Layout.alignment: Qt.AlignHCenter
                                                    text: "History appears after the daemon writes daily quota or local usage snapshots."
                                                    color: root.theme.textDim
                                                    font.family: root.textFont
                                                    font.pixelSize: 11
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    CardFrame {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: root.activeView === "settings"
                        accent: root.theme.textBody

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 14

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10

                                ProviderIconBubble {
                                    icon: root.glyphs.settings
                                    accent: root.theme.textBody
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 3

                                    Label {
                                        text: "Settings"
                                        color: root.theme.text
                                        font.family: root.textFont
                                        font.pixelSize: 18
                                        font.bold: true
                                    }

                                    Label {
                                        Layout.fillWidth: true
                                        text: root.compactJoin([viewData.summary.refreshModeLabel, viewData.summary.notificationsLabel, viewData.summary.privacyLabel])
                                        color: root.theme.textBody
                                        font.family: root.textFont
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            SectionHeader {
                                text: "Runtime Cadence"
                                icon: root.glyphs.refresh
                                accent: root.theme.textDim
                            }

                            GridLayout {
                                Layout.fillWidth: true
                                columns: 6
                                columnSpacing: 8
                                rowSpacing: 8

                                CodexButton { Layout.fillWidth: true; text: "Manual"; glyph: root.glyphs.pin; accent: viewData.summary.refreshModeLabel === "Manual refresh" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.runtimeCommand("manual") }
                                CodexButton { Layout.fillWidth: true; text: "1m"; accent: viewData.summary.refreshModeLabel === "60s refresh" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.runtimeCommand("interval", "60") }
                                CodexButton { Layout.fillWidth: true; text: "2m"; accent: viewData.summary.refreshModeLabel === "120s refresh" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.runtimeCommand("interval", "120") }
                                CodexButton { Layout.fillWidth: true; text: "5m"; accent: viewData.summary.refreshModeLabel === "300s refresh" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.runtimeCommand("interval", "300") }
                                CodexButton { Layout.fillWidth: true; text: "15m"; accent: viewData.summary.refreshModeLabel === "900s refresh" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.runtimeCommand("interval", "900") }
                                CodexButton { Layout.fillWidth: true; text: "30m"; accent: viewData.summary.refreshModeLabel === "1800s refresh" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.runtimeCommand("interval", "1800") }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 14

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    SectionHeader { text: "Display"; icon: root.glyphs.meter; accent: root.theme.textDim }

                                    GridLayout {
                                        Layout.fillWidth: true
                                        columns: 5
                                        columnSpacing: 8
                                        rowSpacing: 8

                                        CodexButton { Layout.fillWidth: true; text: "Remaining"; accent: viewData.summary.showUsedLabel === "Remaining" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.displayCommand("remaining") }
                                        CodexButton { Layout.fillWidth: true; text: "Used"; accent: viewData.summary.showUsedLabel === "Used" ? root.theme.info : root.theme.textMuted; compact: true; onClicked: root.displayCommand("used") }
                                        CodexButton { Layout.fillWidth: true; text: "Both"; accent: viewData.summary.metricModeLabel === "both" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.displayCommand("mode", "both") }
                                        CodexButton { Layout.fillWidth: true; text: "Percent"; accent: viewData.summary.metricModeLabel === "percent" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.displayCommand("mode", "percent") }
                                        CodexButton { Layout.fillWidth: true; text: "Pace"; accent: viewData.summary.metricModeLabel === "pace" ? root.theme.good : root.theme.textMuted; compact: true; onClicked: root.displayCommand("mode", "pace") }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    SectionHeader { text: "Privacy And Notifications"; icon: root.glyphs.bell; accent: root.theme.textDim }

                                    GridLayout {
                                        Layout.fillWidth: true
                                        columns: 3
                                        columnSpacing: 8
                                        rowSpacing: 8

                                        CodexButton { Layout.fillWidth: true; text: viewData.summary.notificationsLabel === "Notify on" ? "Notify Off" : "Notify On"; glyph: root.glyphs.bell; accent: viewData.summary.notificationsLabel === "Notify on" ? root.theme.info : root.theme.textMuted; compact: true; onClicked: root.notificationCommand(viewData.summary.notificationsLabel !== "Notify on") }
                                        CodexButton { Layout.fillWidth: true; text: viewData.summary.privacyLabel === "Privacy on" ? "Show ID" : "Hide ID"; glyph: root.glyphs.privacy; accent: viewData.summary.privacyLabel === "Privacy on" ? root.theme.warn : root.theme.textMuted; compact: true; onClicked: root.privacyCommand(viewData.summary.privacyLabel !== "Privacy on") }
                                        CodexButton { Layout.fillWidth: true; text: "Status"; glyph: root.glyphs.status; accent: root.theme.info; compact: true; onClicked: root.runTokenMaxx(["status"]) }
                                    }
                                }
                            }

                            SectionHeader {
                                text: "Local Scans"
                                icon: root.glyphs.cost
                                accent: root.theme.textDim
                            }

                            GridLayout {
                                Layout.fillWidth: true
                                columns: 3
                                columnSpacing: 8
                                rowSpacing: 8

                                CodexButton { Layout.fillWidth: true; text: "Usage Scan"; glyph: root.glyphs.cost; accent: root.theme.warn; compact: true; onClicked: root.runTokenMaxx(["cost"]) }
                                CodexButton { Layout.fillWidth: true; text: "Storage Scan"; glyph: root.glyphs.storage; accent: root.theme.info; compact: true; onClicked: root.runTokenMaxx(["storage"]) }
                                CodexButton { Layout.fillWidth: true; text: "Refresh Now"; glyph: root.glyphs.refresh; accent: root.theme.good; compact: true; onClicked: root.runTokenMaxx(["refresh"]) }
                            }

                            SectionHeader {
                                text: "Clear Cache"
                                icon: root.glyphs.close
                                accent: root.theme.textDim
                            }

                            GridLayout {
                                Layout.fillWidth: true
                                columns: 5
                                columnSpacing: 8
                                rowSpacing: 8

                                CodexButton { Layout.fillWidth: true; text: "Status"; accent: root.theme.info; compact: true; onClicked: root.cacheCommand("status") }
                                CodexButton { Layout.fillWidth: true; text: "History"; accent: root.theme.warn; compact: true; onClicked: root.cacheCommand("history") }
                                CodexButton { Layout.fillWidth: true; text: "Usage"; accent: root.theme.warn; compact: true; onClicked: root.cacheCommand("cost") }
                                CodexButton { Layout.fillWidth: true; text: "Storage"; accent: root.theme.info; compact: true; onClicked: root.cacheCommand("storage") }
                                CodexButton { Layout.fillWidth: true; text: "All"; accent: root.theme.bad; compact: true; onClicked: root.cacheCommand("all") }
                            }

                            Item { Layout.fillHeight: true }
                        }
                    }

                    CardFrame {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.dense ? 172 : 230
                        visible: root.activeView === "detail"
                        accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: root.dense ? 8 : 12
                            spacing: root.dense ? 6 : 10

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 12

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: root.dense ? 4 : 6

                                    SectionHeader {
                                        text: "Focus"
                                        icon: root.glyphs.pin
                                        accent: root.theme.textDim
                                    }

                                    GridLayout {
                                        Layout.fillWidth: true
                                        columns: 3
                                        columnSpacing: 8
                                        rowSpacing: 8

                                        CodexButton {
                                            Layout.fillWidth: true
                                            text: focusProvider() ? ("Pin " + focusProvider().shortLabel) : "Pin"
                                            glyph: root.glyphs.pin
                                            accent: focusProvider() ? statusColor(focusProvider()) : root.theme.good
                                            compact: true
                                            enabled: !!(focusProvider() && focusProvider().enabled)
                                            onClicked: {
                                                if (focusProvider()) {
                                                    root.runTokenMaxx(["providers", "pin", focusProvider().id])
                                                }
                                            }
                                        }

                                        CodexButton {
                                            Layout.fillWidth: true
                                            text: "Auto"
                                            glyph: root.glyphs.auto
                                            accent: root.theme.info
                                            compact: true
                                            onClicked: root.runTokenMaxx(["providers", "auto"])
                                        }

                                        CodexButton {
                                            Layout.fillWidth: true
                                            text: "Dashboard"
                                            glyph: root.glyphs.dashboard
                                            accent: root.theme.warn
                                            compact: true
                                            enabled: !!(focusProvider() && focusProvider().dashboardUrl)
                                            onClicked: {
                                                if (focusProvider() && focusProvider().dashboardUrl) {
                                                    root.runTokenMaxx(["open", "dashboard", focusProvider().id])
                                                }
                                            }
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: root.dense ? 4 : 6

                                    SectionHeader {
                                        text: "Provider"
                                        icon: root.glyphs.provider
                                        accent: root.theme.textDim
                                    }

                                    GridLayout {
                                        Layout.fillWidth: true
                                        columns: 4
                                        columnSpacing: 8
                                        rowSpacing: 8

                                        CodexButton {
                                            Layout.fillWidth: true
                                            text: focusProvider() && focusProvider().enabled ? "Deactivate" : "Activate"
                                            glyph: focusProvider() && focusProvider().enabled ? root.glyphs.close : root.glyphs.display
                                            accent: focusProvider() && focusProvider().enabled ? root.theme.bad : root.theme.good
                                            compact: true
                                            enabled: !!focusProvider()
                                            onClicked: {
                                                if (focusProvider()) {
                                                    root.providerCommand(focusProvider().enabled ? "deactivate" : "activate", focusProvider().id)
                                                }
                                            }
                                        }

                                        CodexButton {
                                            Layout.fillWidth: true
                                            text: focusProvider() && focusProvider().visible ? "Hide" : "Show"
                                            glyph: focusProvider() && focusProvider().visible ? root.glyphs.hidden : root.glyphs.shown
                                            accent: root.theme.info
                                            compact: true
                                            enabled: !!focusProvider()
                                            onClicked: {
                                                if (focusProvider()) {
                                                    root.providerCommand(focusProvider().visible ? "hide" : "show", focusProvider().id)
                                                }
                                            }
                                        }

                                        CodexButton {
                                            Layout.fillWidth: true
                                            text: focusProvider() && focusProvider().showInOverview ? "Drop Overview" : "Add Overview"
                                            glyph: root.glyphs.overview
                                            accent: root.theme.warn
                                            compact: true
                                            enabled: !!focusProvider()
                                            onClicked: {
                                                if (focusProvider()) {
                                                    root.overviewCommand(focusProvider().showInOverview ? "remove" : "add", focusProvider().id)
                                                }
                                            }
                                        }

                                        CodexButton {
                                            Layout.fillWidth: true
                                            text: focusProvider() && focusProvider().allowAutoSelect ? "Block Auto" : "Allow Auto"
                                            glyph: root.glyphs.auto
                                            accent: root.theme.textBody
                                            compact: true
                                            enabled: !!focusProvider()
                                            onClicked: {
                                                if (focusProvider()) {
                                                    root.providerCommand(focusProvider().allowAutoSelect ? "block-auto" : "allow-auto", focusProvider().id)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: root.dense ? 4 : 6

                                SectionHeader {
                                    text: "Display"
                                    icon: root.glyphs.meter
                                    accent: root.theme.textDim
                                }

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 5
                                    columnSpacing: 8
                                    rowSpacing: 8

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "Remaining"
                                        accent: viewData.summary.showUsedLabel === "Remaining" ? root.theme.good : root.theme.textMuted
                                        compact: true
                                        onClicked: root.displayCommand("remaining")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "Used"
                                        accent: viewData.summary.showUsedLabel === "Used" ? root.theme.info : root.theme.textMuted
                                        compact: true
                                        onClicked: root.displayCommand("used")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "Both"
                                        accent: viewData.summary.metricModeLabel === "both" ? root.theme.good : root.theme.textMuted
                                        compact: true
                                        onClicked: root.displayCommand("mode", "both")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "Percent"
                                        accent: viewData.summary.metricModeLabel === "percent" ? root.theme.good : root.theme.textMuted
                                        compact: true
                                        onClicked: root.displayCommand("mode", "percent")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "Pace"
                                        accent: viewData.summary.metricModeLabel === "pace" ? root.theme.good : root.theme.textMuted
                                        compact: true
                                        onClicked: root.displayCommand("mode", "pace")
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: root.dense ? 4 : 6

                                SectionHeader {
                                    text: "Runtime"
                                    icon: root.glyphs.settings
                                    accent: root.theme.textDim
                                }

                                GridLayout {
                                    Layout.fillWidth: true
                                    columns: 8
                                    columnSpacing: 8
                                    rowSpacing: 8

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "Manual"
                                        glyph: root.glyphs.pin
                                        accent: viewData.summary.refreshModeLabel === "Manual refresh" ? root.theme.good : root.theme.textMuted
                                        compact: true
                                        onClicked: root.runtimeCommand("manual")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "1m"
                                        accent: viewData.summary.refreshModeLabel === "60s refresh" ? root.theme.good : root.theme.textMuted
                                        compact: true
                                        onClicked: root.runtimeCommand("interval", "60")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "2m"
                                        accent: viewData.summary.refreshModeLabel === "120s refresh" ? root.theme.good : root.theme.textMuted
                                        compact: true
                                        onClicked: root.runtimeCommand("interval", "120")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "5m"
                                        accent: viewData.summary.refreshModeLabel === "300s refresh" ? root.theme.good : root.theme.textMuted
                                        compact: true
                                        onClicked: root.runtimeCommand("interval", "300")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: viewData.summary.notificationsLabel === "Notify on" ? "Notify Off" : "Notify On"
                                        glyph: root.glyphs.bell
                                        accent: viewData.summary.notificationsLabel === "Notify on" ? root.theme.info : root.theme.textMuted
                                        compact: true
                                        onClicked: root.notificationCommand(viewData.summary.notificationsLabel !== "Notify on")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: viewData.summary.privacyLabel === "Privacy on" ? "Show ID" : "Hide ID"
                                        glyph: root.glyphs.privacy
                                        accent: viewData.summary.privacyLabel === "Privacy on" ? root.theme.warn : root.theme.textMuted
                                        compact: true
                                        onClicked: root.privacyCommand(viewData.summary.privacyLabel !== "Privacy on")
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "Status"
                                        glyph: root.glyphs.status
                                        accent: root.theme.info
                                        compact: true
                                        onClicked: root.runTokenMaxx(["status"])
                                    }

                                    CodexButton {
                                        Layout.fillWidth: true
                                        text: "Usage"
                                        glyph: root.glyphs.cost
                                        accent: root.theme.warn
                                        compact: true
                                        onClicked: root.runTokenMaxx(["cost"])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    }
}
