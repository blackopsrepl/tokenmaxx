# Providers

The Linux release supports exactly:

- `codex`
- `claude`
- `gemini`
- `opencode`
- `zai`
- `ollama`

## Codex

- Source label: `codex-cli`.
- Runtime path: `codex --sandbox read-only --ask-for-approval never app-server --stdio`.
- RPC methods:
  - `initialize`
  - `account/read`
  - `account/rateLimits/read`
- Dashboard: `https://chatgpt.com/codex`

TokenMaxx reads the `codex` entry from `rateLimitsByLimitId` when present and falls back to the backward-compatible `rateLimits` snapshot. It identifies the five-hour and weekly windows by their declared 300-minute and 10,080-minute durations instead of assuming that `primary` and `secondary` always retain fixed meanings. A missing weekly window remains absent. For non-Pro ChatGPT plans, an omitted five-hour value is surfaced as unavailable rather than converted into a fabricated percentage; Pro continues to expose only the windows returned for that account.

There is no PTY fallback in the current Ruby implementation.
Local token summaries are read from Codex session JSONL logs by `tokenmaxx cost`; monetary cost is reported only when an exact cost exists in the source record. Token counts are attributed to the model declared by the session's `turn_context` records, so summaries preserve per-model token totals alongside the daily breakdown.

## Claude

- Source label: `oauth`.
- Credentials: `~/.claude/.credentials.json`.
- Usage endpoint: `https://api.anthropic.com/api/oauth/usage`.
- Token refresh endpoint: `https://platform.claude.com/v1/oauth/token`.
- Dashboard: `https://claude.ai/`

There is no browser-cookie, secret-store, or CLI scrape in the current Ruby implementation.
Local token summaries are read from Claude project JSONL logs by `tokenmaxx cost`; telemetry files are ignored. Token counts are attributed to each record's `message.model`, so summaries preserve per-model token totals alongside the daily breakdown.

## Gemini

- Source label: `api`.
- Credentials: `~/.gemini/oauth_creds.json`.
- Settings: `~/.gemini/settings.json`.
- OAuth client metadata: discovered from the installed Gemini CLI package or bundled Gemini CLI chunks.
- Project discovery: Code Assist project from `loadCodeAssist`, then Google Cloud project discovery when needed.
- Quota endpoint: `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`.
- Local usage source: `~/.gemini/tmp/**/chats/*.jsonl`.
- Dashboard: `https://gemini.google.com/`

Gemini quota renders as separate model meters. Each quota bucket preserves the raw model id, for example `gemini-2.5-flash`, `gemini-2.5-pro`, and preview model ids returned by the API. The presenter may choose the highest-used model as the compact display meter, but it must keep all model buckets visible in detail and tooltip surfaces.

Retained history stays model-based: Gemini per-model quota is stored as `modelQuota` and model usage as `modelUsage`, and model buckets are never copied into the primary/secondary/tertiary window lanes. Days with no quota sample and no local usage are omitted from the History view.

Gemini local usage scans Gemini CLI chat JSONL records with `type: "gemini"` and `tokens` fields. Summaries preserve input, cached, output, reasoning/thought, tool, total, daily, and per-model token totals.

API-key and Vertex auth modes are not supported for quota in the current independent Linux implementation unless usable OAuth credentials are also present for Code Assist quota.

## OpenCode Go

- Source label: `opencode-go`.
- Provider label: OpenCode Go (distinct from Z.ai-routed usage in the same database).
- Credentials: `~/.local/share/opencode/auth.json` (the `opencode-go` API key, falling back to the `opencode` entry).
- Usage endpoint: `https://opencode.ai/zen/go/v1/usage`.
- Local usage source: `~/.local/share/opencode/opencode.db` (the OpenCode SQLite usage database).
- Dashboard: `https://opencode.ai/`

OpenCode Go exposes three subscription allowance windows as returned by the usage endpoint: `rolling` (five-hour), `weekly`, and `monthly`. Each window reports a used `percent` and a `resetsAt` timestamp. TokenMaxx maps `rolling` to the primary lane, `weekly` to the secondary lane, and `monthly` to the tertiary lane, matching the Codex window shape. Percentages are used percentages, matching the OpenCode console; a missing window stays absent.

OpenCode Go local usage is read from assistant messages in the OpenCode usage database whose `providerID` is `opencode-go`, so usage driven through other providers in the same harness (for example OpenAI/ChatGPT, Moonshot/Kimi, or the free Zen models under `providerID` `opencode`) is not attributed to the subscription. Each message contributes its input, cached read/write, output, and reasoning tokens plus monetary cost to the message's activity date and model id. This preserves model switches and sessions that span multiple days. The scanner groups these message records in SQLite before Ruby summarizes them, keeping refreshes bounded even for larger databases. Reading requires the `sqlite3` binary; when it is unavailable the provider is reported as unsupported rather than fabricated.

## Z.ai

- Source label: `zai-coding-plan`.
- Credentials: `ZAI_API_KEY` or `GLM_API_KEY`, falling back to the `zai-coding-plan` key in `~/.local/share/opencode/auth.json`.
- Quota endpoint: `https://api.z.ai/api/monitor/usage/quota/limit`.
- Dashboard: `https://z.ai/manage-apikey/coding-plan/personal/my-plan`

Z.ai tracks the GLM Coding Plan subscription allowance, not pay-as-you-go API credit. The quota endpoint returns a `limits` array of used-percentage windows; TokenMaxx reads each `TOKENS_LIMIT`/`CREDIT_LIMIT` entry and maps the five-hour unit (3) to the primary lane and the weekly unit (6) to the secondary lane. A monthly `TIME_LIMIT` entry maps to the tertiary lane when the account returns one; a missing window stays absent. Reset times are returned as epoch milliseconds. The account plan tier is shown in the provider identity.

Z.ai local usage is read from the OpenCode usage database, filtered to assistant messages whose provider is `zai-coding-plan` or `zai`; those messages are excluded from the OpenCode Go totals (which include only `providerID` `opencode-go`), so no usage is double-counted. The GLM Coding Plan reports no per-token cost, so the Z.ai cost total stays zero.

## Ollama Cloud

- Source label: `ollama-cloud`.
- Provider label: Ollama Cloud.
- Credentials: `OLLAMA_API_KEY`, falling back to the `ollama-cloud` key in `~/.local/share/opencode/auth.json`.
- Balance endpoint: `https://ollama.com/api/balance` (usage history: `https://ollama.com/api/usage?range=24h|7d|30d`, never read for quota).
- Local usage source: `~/.local/share/opencode/opencode.db` (the OpenCode SQLite usage database).
- Dashboard: `https://ollama.com/settings`

Ollama Cloud exposes the account allowance from the authenticated balance endpoint `https://ollama.com/api/balance`, not from the usage time series. An account migrated to monthly credits returns `included.balance_usd` and `included.allowance_usd` in USD with a monthly reset `period` (`from`/`until`, UTC); TokenMaxx maps the used percentage of the included allowance to the primary lane with the `Monthly`/`mo` labels, sets `resetsAt` from `period.until`, and derives the window length from the period (falling back to a fixed 30-day default when the period is absent). An account still on the legacy plan returns `included.session` (five-hour) and `included.weekly` as `remaining_percent` 0..100 values with `resets_at`; TokenMaxx inverts those to used percentages and maps them to the primary and secondary lanes with real reset timestamps. The two shapes are mutually exclusive per account, so a missing shape simply yields no window. The balance endpoint does not return the plan tier, so the provider identity reports the fixed `Ollama Cloud` login method. The usage endpoint `https://ollama.com/api/usage?range=24h|7d|30d` is an accounting time series (request, token, and USD buckets) and carries no allowance data, so the quota meter never reads it.

Ollama Cloud local usage is read from assistant messages in the OpenCode usage database whose `providerID` is `ollama-cloud`, so usage routed through other providers in the same harness is not attributed to the account. Each message contributes its input, cached read/write, output, reasoning, and total tokens plus monetary cost to the message's activity date and model id. Reading requires the `sqlite3` binary; when it is unavailable the provider is reported as unsupported rather than fabricated.

## Hermes local usage

Hermes Agent keeps its own accounting in `~/.hermes/state.db`: every API call it makes is booked in `session_model_usage`, keyed by session, model, `billing_provider`, route, mode, and task. Auxiliary work (title generation, approvals, background review) is recorded there under its own task id and is never folded into the per-session counters, so reading the table cannot double-count against anything else. TokenMaxx reads that table as an additional local usage source for the providers it can drive, so a provider used through Hermes is counted cumulatively with the same provider used through its own CLI.

Rows are attributed only when the Hermes provider id names the same product TokenMaxx meters:

| Hermes `billing_provider` | TokenMaxx provider |
| --- | --- |
| `opencode-go` | `opencode` |
| `zai` | `zai` |
| `ollama-cloud` | `ollama` |
| `openai-codex` | `codex` |
| `anthropic` | `claude` |
| `gemini` | `gemini` |

Every other id stays unattributed and is preserved in `localUsage.hermes.unattributedProviders` with its records and tokens. That includes `opencode` and `opencode-zen` (the Zen and free gateways rather than the Go subscription), `openai-api` (platform billing rather than the ChatGPT/Codex plan), `ollama` (a local server without an account allowance), and `vertex`, `deepseek`, `xai`, `bedrock`, `lmstudio`, and the rest. `anthropic` maps to `claude` because that is the id Hermes routes the Claude subscription through; if you also drive an Anthropic API key through Hermes, exclude it with `localUsage.hermesSkipProviders`.

Accounting rules:

- `records` counts API calls (`api_call_count`), including Hermes' auxiliary calls, because those calls consume the account allowance.
- Each row contributes input, cached read/write, output, reasoning, and total tokens, and is attributed to the UTC day of its last activity (`last_seen`, falling back to the session start for rows written before Hermes recorded activity timestamps). A session that crosses midnight is attributed to the later day.
- Only `actual_cost_usd` is carried into the cost lane. Hermes stores an estimate for providers it cannot price, and an estimate is not a cost.
- Hermes flushes token counters through an asynchronous accounting queue, so a call that just finished may not be in the database yet. The scan converges within seconds; it is not exact at the instant it runs.
- Coverage, not row presence, decides a summary's `sources` entry: a provider the mapping feeds reports the Hermes source even when its Hermes traffic in the window is zero.
- The store is read with the `sqlite3` binary, and a missing database is a no-op. When the database exists but cannot be read (missing `sqlite3`, or a query failure) the summary keeps its CLI source only and the payload records the reason in `localUsage.hermes.note`.

Reads are bounded to the same `localUsage.scanDays` window as every other source, and `TOKENMAXX_HERMES_DB` overrides the database path.

Browser-cookie scraping, WebKit probes, Keychain/libsecret integration, and providers outside `codex`, `claude`, `gemini`, `opencode`, `zai`, and `ollama` are out of scope for this release line.

## Peak / Off-Peak Rate Windows

Some providers bill by time of day. TokenMaxx labels the current period per model from a static schedule table in `lib/tokenmaxx/core/peak.rb`, because none of the supported provider APIs expose the schedule at runtime: the Ollama usage endpoint returns only fraction windows and the Z.ai quota endpoint only `limits[]`.

| Provider | Time-priced models | Peak window (UTC) | Off-peak |
| --- | --- | --- | --- |
| Z.ai GLM Coding Plan | all models | Mon-Fri 14:00-18:00 UTC+8 (`06:00-10:00` UTC) | 50% credit consumption |
| Ollama Cloud | `deepseek-*` only | Mon-Fri 12:00-18:00 | outside the window, all weekend |
| OpenCode Go | `deepseek-*` only | Mon-Fri 01:00-04:00 and 06:00-10:00 | outside the windows, all weekend |

Providers without time-of-day pricing (`codex`, `claude`, `gemini`) and models without a schedule (for example `opencode`'s Kimi, GLM, or Qwen models, or any non-DeepSeek Ollama Cloud model) report no peak state rather than a guess. The state appears as a badge on Overview cards and Provider Detail, a peak card in the detail grid, a per-model marker on local usage rows and model metrics, and a suffix in the Waybar tooltip; the tooltip and detail card also show the current window in the machine's local zone. Peak never appears in the compact Waybar text or CSS classes.

Only the standing recurring schedules are encoded; limited-time vendor promotions are intentionally not tracked, because a hardcoded promotion would keep reporting a discount after it expired. When a vendor changes a standing schedule, update `Core::Peak::SCHEDULES` and this table together.

### Timezone handling

Windows are declared in UTC and everything downstream is timezone-absolute:

- State is evaluated against UTC, so the badge is identical from every zone.
- Each schedule is serialized into the presenter view as a `peakSchedules` map of alternating `[epoch, state]` transitions compiled around now. The QuickShell panel resolves the current state and formats the current window from those epochs against its own clock, so it is exact at every boundary even when the snapshot is stale, and it never reimplements the schedule or the zone logic.
- The window boundaries are converted to the display zone from the zone database at the window's own instant, so DST and non-hour offsets (for example a half-hour or 45-minute zone) render correctly; a window that crosses local midnight shows both weekdays.
- The panel arms a single timer to the next transition instead of polling, so there is no per-second work while the state holds.

The daemon's emitted `windowText` (with `windowStartAt`/`windowEndAt`) is only a fallback; the panel and Waybar tooltip resolve live. It describes the same rate period the panel resolves from the timeline: the peak window while peak is in effect, and the off-peak span while it is not — an off-peak period runs from one window's close to the next one's open, so it can start and end on different dates (the weekend span is three days). `windowText` follows the system zone of the process that rendered the snapshot, which is correct for the desktop it serves.
