# TokenMaxx Repo Wireframe

## Purpose

This repository ships an independent Linux implementation inspired by [the original CodexBar](https://github.com/steipete/CodexBar) by [Steipete](https://github.com/steipete):

- Ruby backend for config, provider fetch, normalization, and runtime state.
- Resident daemon that writes cached snapshots.
- QuickShell panel as the only human-facing UI.
- Waybar JSON renderer for the compact bar chip.
- Deterministic user-prefix install through `Makefile`.
- Optional SolverForge Linux wrapper for the existing Waybar module.
- Optional Omarchy shell bar module on Hyprland, mounting the same cached-state chip.

Supported providers are exactly `codex`, `claude`, `gemini`, `opencode`, `zai`, and `ollama`.

Codex and Claude expose named quota windows. Codex five-hour and weekly windows are classified from their declared durations. Missing percentages are never synthesized: non-Pro ChatGPT accounts keep an omitted five-hour lane visibly unavailable, while an absent weekly lane and omitted Pro lanes stay absent. Gemini exposes separate model meters from the Gemini CLI-backed quota API; model buckets must remain separate in presenter data, tooltips, history, and detail cards. Gemini local usage is read from Gemini CLI chat JSONL records and retained by model when possible. Codex and Claude local usage is read from their session/project JSONL logs and retained by model from each record's declared model. OpenCode Go exposes five-hour rolling, weekly, and monthly allowance windows from the OpenCode Go usage endpoint, mapped to the primary, secondary, and tertiary lanes; missing windows stay absent. OpenCode Go local usage is read from the OpenCode usage database and retained by model, counting only assistant messages with `providerID` `opencode-go` so other harness-routed providers (OpenAI/ChatGPT, Moonshot/Kimi, free Zen `opencode` models) are excluded. Z.ai exposes GLM Coding Plan used-percentage windows from the Z.ai quota endpoint: five-hour and weekly windows map to the primary and secondary lanes, and a monthly tools window maps to the tertiary lane when present; missing windows stay absent. Z.ai local usage is read from Z.ai-routed assistant messages (`providerID` `zai-coding-plan`/`zai`) in the OpenCode usage database, which are excluded from the OpenCode Go totals. Ollama Cloud exposes account allowance windows from the balance endpoint: a migrated account reports a single monthly USD allowance (used percentage, reset timestamp, window length from the reset period) mapped to the primary lane, and an unmigrated account reports the legacy session (five-hour) and weekly remaining percentages mapped to the primary and secondary lanes. Missing shapes stay absent. The usage time-series endpoint carries no allowance data and is never read for quota. Ollama Cloud local usage is read from `ollama-cloud`-routed assistant messages in the OpenCode usage database, kept separate from the OpenCode Go, Z.ai, and other-provider totals. Every provider's local usage is cumulative across the clients that can drive it: the Hermes usage database (`~/.hermes/state.db`) is read as an additional source and merged into each provider whose Hermes provider id names the same product, so a provider used through Hermes is counted next to the same provider used through its own CLI, and each summary carries the `sources` list it covers. Hermes provider ids that name a different product (`opencode-zen`, `openai-api`, `ollama`, and the rest) are never attributed to a meter.

Retained history follows the same provider shape. Window providers keep their primary/secondary/tertiary samples, model-meter providers keep per-model quota without copying model buckets into window lanes, and local-usage fields are re-merged from the current scan window so a corrected local scanner repairs already-retained days. Days with neither a quota sample nor local usage are omitted from the History view.

Peak/off-peak rate state is declared per model in `lib/tokenmaxx/core/peak.rb` from vendor-documented UTC schedules, because no provider API exposes the schedule: Z.ai is provider-wide, and Ollama Cloud and OpenCode Go apply only to their `deepseek-*` models. Providers and models without time-of-day pricing report no state rather than a guess. Only standing recurring schedules are encoded; limited-time promotions are not, so the label never reports a discount after it expires. Peak state surfaces on Overview cards, Provider Detail, model usage rows, model metric cards, and the Waybar tooltip, and never in the compact Waybar text or CSS classes. Schedules are compiled into the view as timezone-absolute `[epoch, state]` transitions; the panel resolves state and formats the current window against its own clock, so the badge is exact at every boundary, correct under DST and non-hour offsets, and shown in local time without repeating the schedule in QML.

## Repository Map

### Runtime

- `bin/tokenmaxx`: executable Ruby entrypoint.
- `lib/tokenmaxx.rb`: top-level load file.
- `lib/tokenmaxx/cli.rb`: command dispatcher and config mutation surface.
- `lib/tokenmaxx/core/`: config version 5, provider metadata, formatting, metrics, peak/off-peak schedules, process, HTTP.
- `lib/tokenmaxx/providers/`: Codex, Claude, Gemini, OpenCode, Z.ai, and Ollama fetchers and registry.
- `lib/tokenmaxx/runtime/daemon.rb`: provider refresh loop and Waybar signaling.
- `lib/tokenmaxx/runtime/status.rb`: external service status cache for the supported providers.
- `lib/tokenmaxx/runtime/local_usage.rb`: local Codex, Claude, Gemini, OpenCode Go, Z.ai, and Ollama Cloud token usage scanner, attributing OpenCode database messages by provider id and merging the Hermes usage database into every provider its rows name.
- `lib/tokenmaxx/runtime/hermes_usage.rb`: Hermes `state.db` reader, mapping Hermes provider ids to TokenMaxx providers and accounting for rows that map to none.
- `lib/tokenmaxx/runtime/history.rb`: retained daily usage/history summaries, keeping model-meter quota in per-model maps rather than window lanes.
- `lib/tokenmaxx/runtime/storage.rb`: optional provider storage footprint scanner.
- `lib/tokenmaxx/runtime/notifications.rb`: quota and incident notification transitions.
- `lib/tokenmaxx/runtime/server.rb`: read-only cached localhost JSON server.
- `lib/tokenmaxx/runtime/state.rb`: `snapshot.json` and `ui.json` ownership.
- `lib/tokenmaxx/runtime/presenter.rb`: normalized view model for QuickShell and Waybar.
- `lib/tokenmaxx/runtime/quickshell.rb`: QuickShell process and UI-state control.
- `lib/tokenmaxx/runtime/waybar.rb`: cached Waybar render/action commands.
- `lib/tokenmaxx/runtime/omarchy.rb`: sole writer of the Omarchy shell bar module in `~/.config/omarchy/shell.json`.
- `lib/tokenmaxx/runtime/swaybar.rb`: bounded legacy direct-bar command, not the release UI.
- `frontend/quickshell/shell.qml`: panel UI.

### Install and Release

- `Makefile`: install, configure, validation, smoke, and SolverForge integration targets.
- `packaging/solverforge-linux/solverforge-waybar-tokenmaxx`: checked-in source for the SolverForge Waybar wrapper.
- `bin/release-check`: canonical release validation script used by `make check`.
- `version.env`: current release version metadata.
- Release publication pushes `main` and release tags to both remotes: `git.local` (Forgejo at `vigilance:3002`) and `blackopsrepl` (GitHub).

### Documentation

- `README.md`: product overview, install, runtime command surface, and validation path.
- `AGENTS.md`: repo-local implementation, testing, documentation, and release rules.
- `WIREFRAME.md`: current repo/runtime/install map.
- `docs/installation.md`: install and rename-safety procedure.
- `docs/runtime-contracts.md`: config, snapshot, UI state, and Waybar contracts.
- `docs/architecture.md`: backend/frontend data flow.
- `docs/providers.md`: implemented provider fetch paths.
- `docs/cli.md`: command reference.
- `docs/configuration.md`: config fields and semantics.
- `docs/ui.md`: QuickShell and Waybar UI behavior.
- `docs/RELEASING.md`: release gates.

The top-level release truth is `README.md`, `AGENTS.md`, `WIREFRAME.md`, and `docs/`.

## Runtime Flow

1. User session or desktop starts `tokenmaxx daemon --config ~/.config/tokenmaxx/config.json`.
2. The daemon reads enabled providers from config.
3. Provider fetchers return raw usage payloads or explicit provider errors.
4. Auxiliary runtime modules refresh due status, local-usage, storage, notification, and history caches.
5. `Runtime::Usage` resolves the display provider, visible providers, overview providers, and auto-select candidates.
6. `Runtime::Presenter` builds the normalized view model.
7. `Runtime::State` writes `snapshot.json` under `runtime.stateDir`.
8. Waybar calls `tokenmaxx waybar render` and reads cached state only.
9. Waybar clicks call the wrapper, which opens the QuickShell panel or refreshes.
10. QuickShell reads `snapshot.json` and `ui.json`, then sends mutations back through CLI commands.

On a Hyprland/Omarchy desktop, step 8 runs through the `tokenmaxx` module that `tokenmaxx omarchy install` places in `~/.config/omarchy/shell.json`; the Omarchy shell invokes the same `tokenmaxx waybar render` cached-state contract, and `Runtime::Omarchy` is the sole writer of that config.

Provider visibility, activation, overview membership, and auto-select commands update local config and rebuild cached snapshot state immediately. They do not synchronously fetch provider quota.

Provider refresh failures retain the last successful quota sample with its original timestamp while exposing the current error and a cached-data note.

The QuickShell panel has four views:

- Overview: active display provider, state badges, a cumulative token usage heatmap summing local tokens across every provider, and compact cards for enabled, visible providers that are in overview. Every overview member renders; there is no fixed provider cap.
- Provider Detail: focused provider quota, status, local usage (labelled with the stores it covers), history/storage summaries, alerts, provider rail, and provider actions.
- History: presenter-rendered retained daily history for the focused provider, including a token usage heatmap (week-aligned day grid with a single fill ramp for daily local token totals and inline usage stats) and per-model quota for model-meter providers; days with no quota sample or local usage are omitted and the view falls back to its empty state.
- Settings: cadence, display, notification, privacy, scan, and cache-clear controls.

The QuickShell panel is a modal overlay. It stays above application windows, ignores layer-shell exclusion, and uses a relaxed vertical footprint with scrolling where detail content exceeds the available height. Its input mask covers the modal frame only, so clicks outside the card pass through to the desktop instead of dismissing the panel; it closes with its close button or Escape. The provider rail scrolls so every configured provider stays selectable, screens shorter than 820 panel pixels switch to a dense layout instead of squeezing the content area, and under the narrow 720 pixel breakpoint the fixed provider rail and detail action rail drop out so the detail column keeps a readable width. Peak badges resolve live from the compiled schedule timelines and fall back to the static peak fields in a snapshot that carries no timeline.

Waybar is intentionally smaller than the modal: it renders provider icon, quota percentages, provider/display classes, health classes, and tooltip detail. It does not render pace/reserve/hot text or pace classes.

## State Contracts

### Config

- Default path: `~/.config/tokenmaxx/config.json`.
- Version: `5`.
- Provider fields: `id`, `enabled`, `visible`, `showInOverview`, `allowAutoSelect`, `source`.
- Display fields: `mergeIcons`, `showHighestUsage`, `showUsed`, `resetStyle`, `displayMode`, `metricPreferences`, `overviewProviders`, `selectedProvider`. `overviewProviders` is an ordering preference for the overview set, not a cap; every enabled, visible provider with `showInOverview` renders.
- Runtime fields: `refreshSeconds`, `refreshMode`, `notificationCommand`, `stateDir`, `waybarSignal`, `quickShellCommand`, `quickShellShell`.
- Auxiliary fields: `status`, `notifications`, `history`, `localUsage`, `storage`, `privacy`, `server`.

### Snapshot

- Default path: `~/.local/state/tokenmaxx/snapshot.json`.
- Owned by Ruby runtime.
- Read by QuickShell and Waybar.
- Contains enabled/visible/hidden/overview/auto-select provider lists, selected/display provider ids, provider results, and rendered view data.
- Contains auxiliary `serviceStatus`, `localUsage`, `storage`, and `history` payloads.
- Gemini provider results use `usage.meters`, with keys like `model:gemini-2.5-pro` and labels preserving the raw model id. Gemini local usage and retained history include model maps when Gemini CLI records include model ids; retained history keeps model quota in `modelQuota` and model usage in `modelUsage` and never copies model buckets into the primary/secondary/tertiary lanes.

### UI State

- Default path: `~/.local/state/tokenmaxx/ui.json`.
- Owned by Ruby CLI commands.
- Read by QuickShell.
- Tracks whether the panel is open and which provider should be focused.

## Command Surface

### Runtime Commands

- `tokenmaxx daemon`: run the resident refresh loop.
- `tokenmaxx refresh`: fetch once and signal Waybar.
- `tokenmaxx usage`: fetch usage directly for CLI output.
- `tokenmaxx panel`: open QuickShell.
- `tokenmaxx ui open|close|toggle|status`: control or inspect panel state.
- `tokenmaxx waybar render|refresh|panel|cycle-next|cycle-prev`: Waybar render and action hooks.
- `tokenmaxx omarchy install|remove|status`: mount or drop the cached-state chip as an Omarchy shell bar module.
- `tokenmaxx status|cost|history|storage`: auxiliary cached status and local intelligence.
- `tokenmaxx serve`: read-only local JSON endpoints.

### Config Commands

- `tokenmaxx config init|validate`
- `tokenmaxx providers list|activate|deactivate|show|hide|allow-auto|block-auto|pin|auto`
- `tokenmaxx providers overview add|remove`
- `tokenmaxx display status|used|remaining|mode`
- `tokenmaxx runtime status|cadence`
- `tokenmaxx notifications status|enable|disable`
- `tokenmaxx privacy status|hide|show`
- `tokenmaxx cache clear ...`
- `tokenmaxx open dashboard codex|claude|gemini|opencode|zai|ollama`

## Install Flow

1. `make install` copies a manifest of release files into `~/.local/share/tokenmaxx`.
2. `make install` links `~/.local/bin/tokenmaxx` to the installed entrypoint.
3. `make configure-user` creates config if missing.
4. `make configure-user` preserves user provider/display settings and updates only `runtime.quickShellShell`.
5. `make install-solverforge-linux-integration` installs the SolverForge wrapper only when explicitly requested.
6. `make install` does not touch the Omarchy shell config. On a Hyprland/Omarchy desktop, `tokenmaxx omarchy install` seeds `~/.config/omarchy/shell.json` from the Omarchy defaults if needed and inserts the `tokenmaxx` command module; `tokenmaxx omarchy remove` drops it.
7. Restart `tokenmaxx daemon` and the QuickShell panel after installing: the install swaps the installed directory, so running processes keep executing the previous code and file watchers do not fire (see "Restart After Install" in `docs/installation.md`).

After install/configure, the live desktop must not depend on the checkout directory path.

## Release Validation Flow

1. `make syntax`: Bash syntax plus per-file Ruby syntax checks.
2. `make test`: built-in Ruby test suite.
3. `make smoke`: config, Waybar render, and UI status smoke checks.
4. `make check`: canonical preview release gate via `bin/release-check`.
5. `make check-live`: credentialed stable release gate for Codex, Claude, Gemini, OpenCode, Z.ai, and Ollama Cloud.

Release cutting, deployment, and publication to both remotes follow the step-by-step workflow in `docs/RELEASING.md`.

`make check-live` can fail because credentials or upstream provider auth are missing or invalid. That is a live release-environment blocker, not a regression in the local unit suite.

## Current Non-Goals

- no retired upstream desktop packaging flow
- no macOS runtime surface
- no Homebrew, Sparkle, or WebKit release path
- no Swift or TypeScript runtime
- no alternate TokenMaxx product fallback
- no providers outside the implemented Linux scope
- no provider fetches from Waybar
- no provider fetches from local server request handlers
- no synchronous provider quota fetches from provider state toggles
- no broad install copy of the development checkout
