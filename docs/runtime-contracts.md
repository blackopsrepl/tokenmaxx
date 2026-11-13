# Runtime Contracts

TokenMaxx uses files and CLI commands as the boundary between the Ruby backend, QuickShell, and Waybar.

## Config

Location:

```text
~/.config/tokenmaxx/config.json
```

Important fields:

- `version`: current config version, currently `5`.
- `providers[]`: `id`, `enabled`, `visible`, `showInOverview`, `allowAutoSelect`, `source`.
- `display.showHighestUsage`: automatic highest-usage display mode.
- `display.selectedProvider`: pinned provider when automatic mode is off.
- `display.showUsed`: used vs remaining percent.
- `display.displayMode`: `both`, `percent`, or `pace`.
- `runtime.refreshSeconds`: daemon cadence.
- `runtime.refreshMode`: `interval` or `manual`.
- `runtime.stateDir`: state directory.
- `runtime.waybarSignal`: RT signal for Waybar repaint.
- `runtime.quickShellCommand`: QuickShell executable.
- `runtime.quickShellShell`: installed QML entrypoint.
- `status.enabled`, `status.refreshSeconds`: external status polling.
- `notifications.*`: quota and incident notification settings.
- `history.*`: daily snapshot retention.
- `localUsage.*`: local Codex, Claude, Gemini, OpenCode Go, and Z.ai scan controls; Z.ai and Ollama Cloud read their routed messages from the OpenCode usage database. Every provider summary also merges the Hermes usage database for the providers its rows name, and `localUsage.hermesSkipProviders` excludes providers from that merge.
- `storage.*`: provider storage footprint scan controls.
- `privacy.hidePersonalInfo`: redacts identity text in the UI.
- `server.host`, `server.port`: read-only local JSON server binding.

## Snapshot

Location:

```text
~/.local/state/tokenmaxx/snapshot.json
```

Current shape:

```json
{
  "snapshotVersion": 4,
  "generatedAt": "2026-05-06T00:00:00Z",
  "enabledProviders": ["codex"],
  "visibleProviders": ["codex"],
  "hiddenProviders": [],
  "overviewProviders": ["codex"],
  "autoSelectableProviders": ["codex"],
  "selectedProvider": "codex",
  "displayProvider": "codex",
  "serviceStatus": {},
  "localUsage": {},
  "storage": {},
  "history": {},
  "results": {},
  "view": {}
}
```

The Ruby runtime owns this file. QuickShell reads it; QuickShell must not reimplement provider fetching.

When a provider refresh fails after a successful sample, the daemon retains that provider's last good `usage` and `credits`, records the current error, and adds a note that cached quota is being shown. The original usage timestamp remains authoritative, so consumers can distinguish cached quota from a fresh provider response.

`view` is presenter-owned data for QuickShell and Waybar. The view carries a top-level `heatmap` aggregating every provider's retained days into one cumulative token series for the Overview, top-level `peakSchedules` mapping every declared schedule id to a `{detail, transitions[]}` timeline of timezone-absolute `[epoch, 1|0]` pairs, and provider entries include view-ready quota metrics, explicit `unavailableMetrics`, a compact `quotaSummaryText`, an optional `peak` state (`{scheduleId, state, label, detail, windowStartAt, windowEndAt, windowText, models[]}`) derived from the declared schedules for time-priced models, whose window fields describe the rate period in effect — the peak window while peak is in effect, the off-peak span while it is not — service status text, local usage text, a `localUsageSourcesText` naming the local stores that summary covers, optional `localUsageModels` (each carrying its own per-model `peak`), storage text, retained `historyDays`, a `historyHeatmap` (dense week-aligned day cells with token intensity buckets, a `present` flag distinguishing retained-but-tokenless days from gaps, per-cell `tooltipText`, plus `stats` for window, active days, streak, best day, and peak), and `historySummary` so the QML panel does not parse raw provider payloads. The panel resolves peak state live from the `peakSchedules` timeline named by `scheduleId`; when a peak names no resolvable timeline, the panel falls back to the peak's static `state`/`label`/`windowText`/`detail` fields. An unavailable metric has no percentage and must not participate in severity, pace, or automatic provider selection.

## Auxiliary State

All files live under `runtime.stateDir`, are owned by Ruby, and are written with `0600` permissions:

- `status.json`: schema version 2 scoped vendor status, incident associations, source coverage/freshness and separate account observations for all six supported providers. Provider `state` is scoped, never the vendor-global indicator. See [Status](status.md).
- `local_usage.json`: exact local token/cost summaries from Codex and Claude logs plus Gemini CLI chat token summaries and OpenCode usage database summaries. Every provider summary can include a `models` map keyed by model id: Codex uses the session `turn_context` model, Claude the record `message.model`, and Gemini and OpenCode the source model id. Z.ai entries summarize Z.ai-routed assistant messages (`providerID` `zai-coding-plan`/`zai`) from the OpenCode usage database, Ollama Cloud entries summarize only assistant messages with `providerID` `ollama-cloud`, and OpenCode Go entries summarize only assistant messages with `providerID` `opencode-go`, so Z.ai and Ollama Cloud rows and other harness-routed providers are never attributed to OpenCode Go. Every provider summary also carries `sources`, the list of stores it covers (`codex-jsonl`, `claude-jsonl`, `gemini-jsonl`, `opencode-db`, and `hermes` when the Hermes usage database is readable and the provider is not excluded): a provider driven through Hermes is merged from `~/.hermes/state.db`'s `session_model_usage` rows on top of its CLI store, attributed by Hermes provider id through the mapping in `docs/providers.md`, so the two clients sum into one provider's totals, model rows, and days. The payload also carries `hermes` with `available`, `dbPath`, `note` (read failures), and `unattributedProviders` (records and tokens per Hermes provider id that deliberately maps to no TokenMaxx provider).
- `history.json`: daily retained quota/local-usage summaries. Window providers keep primary/secondary/tertiary samples; Gemini meter providers keep per-model quota in `modelQuota` and model usage in `modelUsage` keyed by raw model id without synthesizing window lanes. Local-usage fields (tokens, records, cost, `modelUsage`) are re-merged from the current scan window on every update, so a corrected local scanner repairs already-retained days. Days with neither a quota sample nor local usage are omitted from the presenter's `historyDays`, so a provider with no samples yields the History empty state.
- `storage.json`: optional provider storage footprint summaries.
- `notification_state.json`: last notification state to prevent repeated alerts.

## Scoped Service Status

The status envelope has `schemaVersion: 2`, `generatedAt`, and `providers`.
Each provider carries `state`, `scope`, `description`, `coverage`, `services[]`,
`incidents[]`, `incidentCoverage`, contextual `vendor`, optional account
`observation`, and source metadata. Services preserve component identities and
raw status; incidents preserve identity, current impact, lifecycle, scope,
affected services, vendor update, update text and source link. Multiple incidents
are retained; unassociated incidents have unconfirmed scope.

`updatedAt` is the last successful health observation, `checkedAt` the attempt,
and `staleAt` the expiration. `sources[]` preserves each source's retrieval and
vendor-update timestamps, coverage and error independently. `freshness` is
`fresh`, `stale`, or `unavailable`; stale display becomes `unknown` and retains
`lastKnownState`. A fresh snapshot is not proof of fresh status. Cached CLI and
localhost reads project expiration without writing or fetching. QuickShell reads
the presenter projection and may evaluate its supplied expiration against a
clock; no incident classification lives in QML.

Snapshot version 4 changes service-state semantics: coding status is not a global
vendor indicator, and account observations are not inference health. Old unscoped
status records display unknown until refreshed; quota and history remain intact.

## UI State

Location:

```text
~/.local/state/tokenmaxx/ui.json
```

Shape:

```json
{
  "open": false,
  "focusProvider": "",
  "requestedAt": ""
}
```

Ruby CLI commands write this file when opening, closing, or focusing the panel.

## Omarchy Shell Config

TokenMaxx can mount its cached-state chip as an Omarchy shell bar module so the same contract works on Hyprland.

Command:

```bash
tokenmaxx omarchy install|remove|status
```

Location:

```text
~/.config/omarchy/shell.json
```

`Runtime::Omarchy` is the only TokenMaxx writer of this file. `install` seeds the user file from the Omarchy defaults (`$OMARCHY_PATH/config/omarchy/shell.json`, defaulting to `/usr/share/omarchy/config/omarchy/shell.json`) when it is missing, then inserts one `tokenmaxx` entry of `type: command` into `bar.layout`:

```json
{
  "id": "tokenmaxx",
  "type": "command",
  "exec": "<tokenmaxx> waybar render",
  "interval": 10,
  "onClick": "<tokenmaxx> panel",
  "onMiddleClick": "<tokenmaxx> refresh",
  "tooltip": "TokenMaxx agent quota chip (left: panel, middle: refresh)"
}
```

Default placement is immediately after `omarchy.weather`; `--after`, `--section`, and `--index` override it, and an unresolved anchor falls back to the end of the center section. Reinstalling replaces the existing entry instead of duplicating it. Writes are atomic (temp file + rename), preserve unrelated user keys, and are followed by a best-effort `omarchy-shell shell reloadConfig`. The module renders the same cached-state JSON as the Waybar payload below; the bar never fetches providers.

## Waybar Payload

Command:

```bash
tokenmaxx waybar render
```

Shape:

```json
{
  "text": "CX 97%",
  "tooltip": "Display: Codex",
  "class": ["tokenmaxx", "provider-codex", "healthy"]
}
```

Waybar reads cached state only. It must not fetch providers directly.
Waybar text omits pace/reserve/hot labels and pace classes; those remain modal-only detail.

## Local Server

`tokenmaxx serve` exposes read-only cached JSON endpoints on `server.host:server.port`:

- `/health`
- `/usage`
- `/status`
- `/cost`
- `/history`
- `/storage`

Request handlers read existing cache files only.
