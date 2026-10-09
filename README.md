<p align="center">
  <img src="./tokenmaxx-mascot.png" alt="TokenMaxx mascot" width="320" />
</p>

# TokenMaxx

TokenMaxx is a Linux-first quota bar for Codex, Claude, Gemini, OpenCode Go, Z.ai, and Ollama Cloud. It is an independent Linux implementation inspired by [the original CodexBar](https://github.com/steipete/CodexBar) by [Steipete](https://github.com/steipete).

The current product is a Ruby CLI/backend, a resident snapshot daemon, a compact Waybar JSON renderer, and one QuickShell panel. The supported runtime is Ruby + QuickShell + Waybar.

<p align="center">
  <img src="./tokenmaxx.png" alt="TokenMaxx QuickShell panel showing Codex, Claude, Gemini, OpenCode, Z.ai, and Ollama Cloud quota state" />
</p>

## Current Contract

- Runtime language: Ruby.
- Human-facing UI: `frontend/quickshell/shell.qml`.
- Bar surface: Waybar calls `tokenmaxx waybar render` and receives cached JSON.
- Background fetch path: `tokenmaxx daemon` fetches providers and writes snapshots.
- State files: `snapshot.json` and `ui.json` under `runtime.stateDir`, defaulting to `~/.local/state/tokenmaxx`.
- Config file: `~/.config/tokenmaxx/config.json`, current config version `5`.
- Supported providers: `codex`, `claude`, `gemini`, `opencode`, `zai`, and `ollama`.

Provider fetches do not run inside Waybar. Waybar is only a render/action surface.

The QuickShell panel is split into Overview, Provider Detail, History, and Settings views. It reads presenter data from `snapshot.json` and sends mutations back through the Ruby CLI. Provider toggles update config and the cached snapshot immediately; provider quota fetches happen through `tokenmaxx daemon`, `tokenmaxx refresh`, or `tokenmaxx usage`.

The Waybar chip shows compact provider quota percentages and health classes only. Pace labels such as `reserve` and `hot`, and peak/off-peak labels, stay out of the bar; they appear in the QuickShell panel, provider detail cards, and the Waybar tooltip.

Gemini quota is represented as separate model meters exactly as returned by the Gemini CLI-backed quota API, not as a single blended Pro/Flash pair. Gemini local usage is read from Gemini CLI chat JSONL records under `~/.gemini/tmp/**/chats/`. The provider-level Gemini status aggregates quota model meters: exhausted model buckets are still visible as critical meters, while mixed healthy and exhausted buckets make the provider warning rather than critical.

OpenCode Go quota is represented as its three subscription allowance windows as returned by the OpenCode Go usage endpoint: a five-hour rolling window, a weekly window, and a monthly window. These map to the primary, secondary, and tertiary lanes exactly like Codex. OpenCode Go local usage is read from the OpenCode usage database at `~/.local/share/opencode/opencode.db`, counting only assistant messages with `providerID` `opencode-go`; usage routed through other providers (OpenAI/ChatGPT, Moonshot/Kimi, free Zen `opencode` models) is not part of the subscription and stays excluded. Local usage is cumulative per provider across the clients that can drive it: when `~/.hermes/state.db` exists, the usage Hermes books for `opencode-go` is merged into the same summary, so work done through Hermes counts next to work done through the OpenCode CLI instead of disappearing from the meter.

Z.ai quota is the GLM Coding Plan subscription allowance, not pay-as-you-go API credit. It is read from `https://api.z.ai/api/monitor/usage/quota/limit` as used-percentage windows: a five-hour window and a weekly window map to the primary and secondary lanes, and a monthly tools window maps to the tertiary lane when the account returns one. The API key comes from `ZAI_API_KEY`/`GLM_API_KEY`, or from the `zai-coding-plan` entry in `~/.local/share/opencode/auth.json` when you use Z.ai through OpenCode. Z.ai local usage is read from Z.ai-routed assistant messages in the OpenCode usage database (`providerID` `zai-coding-plan`/`zai`); those messages are separate from the OpenCode Go totals, which count only `providerID` `opencode-go`.

Ollama Cloud quota is the account allowance reported by `https://ollama.com/api/balance`. Accounts migrated to monthly credits report the included allowance as `balance_usd` against `allowance_usd` with a monthly reset `period`, shown in the primary lane with its reset time; accounts on the legacy plan report `session` (five-hour) `remaining_percent` in the primary lane and `weekly` in the secondary lane. The API key comes from `OLLAMA_API_KEY`, or from the `ollama-cloud` entry in `~/.local/share/opencode/auth.json` when Ollama Cloud is configured through OpenCode. The usage time series at `https://ollama.com/api/usage` carries no allowance data and is never read for quota. Ollama local usage is read from the OpenCode usage database, counting only assistant messages with `providerID` `ollama-cloud`.

## Desktop Autostart

TokenMaxx has two separate runtime pieces:

- `tokenmaxx daemon --config ~/.config/tokenmaxx/config.json` refreshes provider quota state and writes `snapshot.json`.
- `tokenmaxx waybar render --config ~/.config/tokenmaxx/config.json` reads that cached snapshot and returns Waybar JSON.

Waybar does not refresh Codex, Claude, Gemini, OpenCode, or Z.ai by itself. If the daemon is not running after login or reboot, the Waybar chip can keep rendering, but it will render stale cached state. A desktop integration should therefore start and supervise the daemon at session startup.

On SolverForge Linux, the managed Waybar integration starts companion daemons through `solverforge-waybar-companions-start`, launched from Sway `exec_always` beside Waybar. That launcher restarts `tokenmaxx daemon` if an early boot-time refresh failure makes it exit.

## Hyprland + Omarchy

On a Hyprland desktop running the Omarchy shell, the Waybar chip mounts as a bar command module:

```bash
tokenmaxx omarchy install   # adds the tokenmaxx module next to omarchy.weather
tokenmaxx omarchy status
tokenmaxx omarchy remove
```

`omarchy install` seeds `~/.config/omarchy/shell.json` from the Omarchy defaults when the user file does not exist yet, inserts a `type: command` module (default placement: `--after omarchy.weather`), and asks the running shell to reload its config. The module polls `tokenmaxx waybar render` on an interval (`--interval`, default 10), opens the QuickShell panel on left click, and triggers a daemon refresh on middle click. The daemon itself is not started by the module; launch it at session startup, for example from Hyprland:

```ini
exec-once = tokenmaxx daemon
```

The `waybar` chip contract is unchanged: Waybar on sway and the Omarchy shell on Hyprland both render the same cached-state JSON. The QuickShell panel follows the active Omarchy theme (live, via `theme/colors.toml`); outside Omarchy it keeps the built-in palette.

## Install

```bash
make install
make configure-user
```

By default this installs to:

- app tree: `~/.local/share/tokenmaxx`
- CLI: `~/.local/bin/tokenmaxx`
- config: `~/.config/tokenmaxx/config.json`
- state: `~/.local/state/tokenmaxx`

`make configure-user` creates the config if missing, preserves provider and display settings, and updates only `runtime.quickShellShell` to the installed QuickShell file.

For SolverForge Linux Waybar integration:

```bash
make install-solverforge-linux-integration
```

That installs the checked-in wrapper used by the existing SolverForge Waybar module. The normal product install does not edit SolverForge desktop config.

## Runtime

Core commands:

```bash
tokenmaxx daemon
tokenmaxx refresh
tokenmaxx usage --provider codex,claude,gemini,opencode,zai,ollama --format json --pretty
tokenmaxx config validate
tokenmaxx waybar render
tokenmaxx omarchy install
tokenmaxx omarchy status
tokenmaxx omarchy remove
tokenmaxx panel
tokenmaxx ui open|close|toggle|status
```

Provider controls:

```bash
tokenmaxx providers list
tokenmaxx providers activate codex
tokenmaxx providers deactivate claude
tokenmaxx providers show gemini
tokenmaxx providers hide gemini
tokenmaxx providers pin codex
tokenmaxx providers auto
tokenmaxx providers overview add claude
tokenmaxx providers overview remove claude
tokenmaxx providers allow-auto gemini
tokenmaxx providers block-auto gemini
```

`activate`, `deactivate`, `show`, `hide`, overview membership, and auto-select changes are local config/snapshot mutations. They do not synchronously fetch provider quota, so UI controls should feel immediate even when a provider credential path is slow or unavailable.

Display controls:

```bash
tokenmaxx display status
tokenmaxx display used
tokenmaxx display remaining
tokenmaxx display mode both
tokenmaxx display mode percent
tokenmaxx display mode pace
```

Runtime, status, and cached local intelligence:

```bash
tokenmaxx runtime status
tokenmaxx runtime cadence manual
tokenmaxx runtime cadence interval 120
tokenmaxx notifications enable
tokenmaxx privacy hide
tokenmaxx status
tokenmaxx cost
tokenmaxx history --format json --pretty
tokenmaxx storage
tokenmaxx cache clear status
tokenmaxx serve --host 127.0.0.1 --port 8765
```

`tokenmaxx serve` exposes cached JSON at `/health`, `/usage`, `/status`, `/cost`, `/history`, and `/storage`. It does not fetch providers from request handlers.

All providers are present in the default config, but provider entries default to disabled. Activate the providers this machine should fetch.

`tokenmaxx bar` remains in the codebase as a bounded legacy direct-bar command. It is not the release UI path.

## Source-Tree Development

```bash
bin/tokenmaxx config validate
bin/tokenmaxx waybar render
bin/tokenmaxx ui status --format json --pretty
```

Open the panel from the checkout:

```bash
env QT_QPA_PLATFORM=wayland \
  TOKENMAXX_BIN=$PWD/bin/tokenmaxx \
  TOKENMAXX_CONFIG=$HOME/.config/tokenmaxx/config.json \
  TOKENMAXX_STATE_DIR=$HOME/.local/state/tokenmaxx \
  quickshell --path $PWD/frontend/quickshell/shell.qml
```

Do not run the live desktop from the checkout if the checkout directory may be renamed. Install first, then run `make configure-user` so the user config points at the installed QuickShell path.

## Supported Providers

The release surface is exactly:

- `codex`
- `claude`
- `gemini`
- `opencode`
- `zai`
- `ollama`

Codex and Claude expose named quota windows. TokenMaxx identifies Codex's five-hour and weekly windows from the durations returned by the Codex app-server rather than relying on response field order. A missing weekly window stays absent. On non-Pro ChatGPT plans, a missing five-hour value remains visibly unavailable in Waybar and QuickShell instead of being assigned a fabricated percentage; Pro displays only the returned account windows. Claude also exposes its Sonnet-specific tertiary window when present. Gemini exposes raw model-meter buckets such as `gemini-2.5-flash`, `gemini-2.5-pro`, and preview model buckets as returned by the Code Assist quota API. Local usage summaries cover Codex, Claude, Gemini, OpenCode Go, Z.ai, and Ollama Cloud; every summary preserves per-model token totals when the source records a model (Codex from `turn_context`, Claude from `message.model`, Gemini from CLI chat logs, OpenCode Go, Z.ai, and Ollama Cloud from the OpenCode usage database).

OpenCode Go exposes its five-hour rolling, weekly, and monthly allowance windows as returned by `https://opencode.ai/zen/go/v1/usage`. Percentages are used percentages, matching the OpenCode console. The five-hour, weekly, and monthly windows map to the primary, secondary, and tertiary lanes respectively; a missing window stays absent.

Z.ai exposes the GLM Coding Plan subscription allowance as used-percentage windows returned by `https://api.z.ai/api/monitor/usage/quota/limit`. The five-hour window maps to the primary lane and the weekly window to the secondary lane; a monthly tools window maps to the tertiary lane when the account returns one, and a missing window stays absent. This is the coding-plan subscription quota, not pay-as-you-go API credit. The API key is read from `ZAI_API_KEY`/`GLM_API_KEY`, or from the `zai-coding-plan` entry in `~/.local/share/opencode/auth.json` when Z.ai is configured through OpenCode. Local usage is read from Z.ai-routed assistant messages in the OpenCode usage database; the coding plan reports no per-token cost, so cost stays zero.

Ollama Cloud exposes the account allowance from `https://ollama.com/api/balance`. A migrated account reports `included.balance_usd` and `included.allowance_usd` with a monthly reset `period`; the lane shows the used percentage of the included allowance, the reset timestamp, and no window cap is fabricated (the fixed 30-day default applies when the period is missing). An unmigrated account reports `included.session` (five-hour) and `included.weekly` as 0..100 `remaining_percent` values with `resets_at`, mapped to the primary and secondary lanes. Missing shapes stay absent. The API key is read from `OLLAMA_API_KEY`, or from the `ollama-cloud` entry in `~/.local/share/opencode/auth.json`. The balance endpoint does not return the plan tier, so the provider identity reports the fixed `Ollama Cloud` login method. Usage history lives separately in `https://ollama.com/api/usage?range=24h|7d|30d`, an accounting time series with no allowance data, so the quota meter never reads it.

Retained history keeps each provider's shape: window providers store their primary/secondary/tertiary samples, Gemini stores per-model quota in `modelQuota` and model usage in `modelUsage`, and days with neither a quota sample nor local usage are omitted so the History view falls back to its empty state. The Overview renders every enabled, visible provider marked `showInOverview`; there is no fixed provider cap.

Some providers bill by time of day. TokenMaxx labels the current peak/off-peak period per model from a static schedule table, because no provider API exposes the schedule. Z.ai's GLM Coding Plan is provider-wide (peak Mon-Fri 14:00-18:00 UTC+8, off-peak at 50% credits). Ollama Cloud and OpenCode Go are model-scoped: only their `deepseek-*` models are time-priced (Ollama peak Mon-Fri 12:00-18:00 UTC; DeepSeek peak Mon-Fri 01:00-04:00 and 06:00-10:00 UTC). Providers and models without time-of-day pricing report no peak state rather than a guess. Only standing recurring schedules are encoded; limited-time promotions are intentionally not tracked so a discount is never reported after it expires. Schedules are compiled into timezone-absolute transition timelines, so the indicator is identical from any timezone, flips exactly at each boundary, and shows the current window in your local time. See `docs/providers.md` for the schedule table and timezone handling.

Other providers are not part of this Linux release.

## Validation

```bash
make syntax
make test
make smoke
make check
```

`make check` delegates to `bin/release-check`. It runs pre-commit, Bash syntax, per-file Ruby syntax, the Ruby test suite, config/smoke checks, Waybar render, UI status, and QuickShell load when QuickShell is available.

Stable release validation on a credentialed machine:

```bash
make check-live
```

`make check-live` requires working live credentials for Codex, Claude, Gemini, OpenCode, Z.ai, and Ollama Cloud. Credential or upstream auth failures are release-environment blockers, not unit-test failures.

Run `make help` for the full colorized target overview. `make version` prints the version from `version.env`, and `make bump-patch`, `make bump-minor`, `make bump-major` (with `make bump-dry` to preview) run `commit-and-tag-version` so releases keep using the repository's `.versionrc.js` contract.

## Documentation

- `AGENTS.md`: repo-local implementation and release rules.
- `WIREFRAME.md`: current runtime, install, and UI contract map.
- `docs/installation.md`: install and SolverForge Linux integration.
- `docs/runtime-contracts.md`: config, snapshot, UI, and Waybar JSON contracts.
- `docs/architecture.md`: runtime architecture.
- `docs/providers.md`: implemented provider fetch paths.
- `docs/status.md`: external service-status cache behavior.
- `docs/cli.md`: command reference.
- `docs/RELEASING.md`: release gates.
