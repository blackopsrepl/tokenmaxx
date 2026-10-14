# UI

TokenMaxx has one human-facing UI: `frontend/quickshell/shell.qml`.

## Waybar Chip

Waybar calls:

```bash
tokenmaxx waybar render
```

The payload includes:

- `text`: compact provider/quota text.
- `tooltip`: multiline detail.
- `class`: CSS classes for provider, health, and display mode.

Waybar does not render pace/reserve/hot text or pace classes. It also does not render peak/off-peak text or classes; peak detail remains in the QuickShell panel and the Waybar tooltip. Pace detail remains available in the QuickShell panel.

The compact Codex chip renders every quota window present in the cached provider response. When a non-Pro ChatGPT account omits its expected five-hour value, the chip keeps that lane visible as `--` beside the real weekly percentage; the modal labels it unavailable. A missing weekly window stays absent, and the UI never turns a missing value into a fabricated percentage.

Click behavior is provided by the desktop wrapper:

- left click: open QuickShell panel
- middle click: refresh
- right click: open QuickShell panel

## QuickShell Panel

The panel reads:

- `snapshot.json`
- `ui.json`

The panel renders:

- summary band
- view tabs for Overview, Provider Detail, History, and Settings
- Overview: active display provider, freshness, service/runtime/privacy state, a cumulative token usage heatmap (single week grid summing local tokens across every provider), and compact cards for enabled, visible overview providers; every overview member renders with no fixed provider cap, and each card shows an equivalent compact summary (five-hour and weekly lanes for window providers, dominant model for model-meter providers, and the provider's own lane label where it declares one, such as Ollama Cloud's monthly `mo` allowance) plus a peak/off-peak badge when the provider has time-of-day pricing
- Provider Detail: focused provider identity, quota hero with a peak/off-peak badge, a peak card showing the current window in local time, service/local/history/storage detail cards (the local usage card names the stores that summary covers), model local usage rows with per-model peak markers when present, alerts, provider rail, and provider actions
- History: retained presenter history for the focused provider, including a daily token usage heatmap (GitHub-style week grid with a single green fill ramp for local token totals, a neutral slate for retained days without local tokens, and inline window/active/streak/best stats), quota bars, local token summaries, and per-model quota for model-meter providers; days with no quota sample or local usage are omitted and the view shows its empty state when no day remains
- Settings: cadence, display mode, notification, privacy, scan, and cache-clear controls

The panel styling is square-cornered: every frame, button, badge, bar, and heatmap cell renders with zero corner radius. Panel polish uses QuickShell primitives only: gradient metric bars with animated fills, hover transitions on buttons, tabs, rail rows, and heatmap cells, a layered square modal shadow, and a fade-in on panel open.

The panel is a bounded bar drop-down, not a screen overlay: the layer surface is exactly the card's rect below the bar edge, and it hangs from the bar edge on the same side its Waybar chip occupies (left of center). Its height is counted from the laid-out parts and capped to the viewport, so the card stays drop-down-shaped rather than growing toward the screen. The desktop outside the surface stays interactive — no scrim, no backdrop catcher, no screen-wide input mask; the surface is transparent only over the card's own rect, and the transparent strip between the bar and the card dismisses on click. The trade: click inside the popover to interact, Esc or the Close button to dismiss (a click on the desktop outside the bounded surface reaches the app underneath; it can no longer close the popover). It takes keyboard focus on demand. On screens shorter than 820 panel pixels (for example 1366x768 laptops) the panel switches to a dense layout — tighter margins, a shorter header and view tabs, and a shorter detail action panel — instead of squeezing the content area; taller screens keep the relaxed layout. Under the narrow 720 pixel breakpoint the fixed provider rail and the detail action rail drop out, the detail column takes the full width, and the non-wrapping header badges hide; rail providers stay selectable from the Provider Detail view. The provider rail scrolls, so every configured provider stays selectable regardless of screen height.

Peak surfaces resolve live against the panel clock from the compiled `peakSchedules` timelines in the snapshot. When a peak cannot be resolved from a timeline (a snapshot written before the daemon compiled schedules, or version skew until the next refresh), the panel falls back to the static `state`/`label`/`windowText`/`detail` fields in that peak and keeps rendering the badge, icon, and window. Those fields describe the current rate period — the peak window while peak is in effect, the off-peak span while it is not — so the fallback shows the same window the timeline path resolves.

On a Hyprland/Omarchy desktop the panel watches `~/.local/state/omarchy/current/theme/colors.toml` (override via `OMARCHY_THEME_COLORS`) and resolves its semantic colors from the active theme's foundational keys, so `omarchy theme set` restyles the open panel live. Missing keys and non-Omarchy systems fall back to the built-in palette.

The panel sends mutations back through the Ruby CLI. It does not fetch provider usage directly.

Provider action controls queue CLI mutations into a small FIFO instead of killing in-flight commands, so rapid clicks on different controls all land. Every action surfaces pending and terminal results on a status line under the view tabs — "Refreshing provider quota", "Deactivating codex", "Scanning usage" — the command's stderr is surfaced there on failure instead of vanishing into debug logs, queued actions stay described until they run, and an error stays visible until the next action starts. Provider on/off, show/hide, overview, and auto-select changes update local config/snapshot state immediately; quota refresh remains daemon/refresh owned.

Runtime controls include manual, 1m, 2m, 5m, 15m, and 30m refresh cadence, notifications, privacy redaction, status refresh, local usage scan, storage scan, and cache clear commands.

## Fonts and Glyphs

The UI uses text plus Nerd Font glyph metadata from the Ruby provider metadata. Missing glyph support affects visual polish but not provider fetching.
