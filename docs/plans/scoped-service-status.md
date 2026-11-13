# Scoped service status and incident reporting

Status: implemented and verified locally.
Repository baseline: main, 2b16c321f9f12505217b5b400b7a4e4e15369ef7.
Evidence checked: 2026-11-13. This is TokenMaxx work in codexbar-sway, not repobar.

## Product contract

Answer three different questions without conflating them:

1. What does the vendor report about the coding services this provider uses?
2. What other vendor incidents are active, and what is their known impact?
3. Can this installation fetch its own quota/account information?

Connector degradation is real degradation. The distinction is relevance and scope,
not real versus fake. Vendor-reported operational is not an end-to-end guarantee
that this user's inference requests work. TokenMaxx must say what it measured.

Keep the existing Overview, Provider Detail, History, Settings, quota-only Waybar
chip, CLI, and read-only localhost JSON surfaces. No new dashboard, inference
probes, credential discovery, model routing, provider IDs, or network calls in QML
or Waybar. Do not introduce AI-based incident classification.

## Source-grounded diagnosis

- core/types.rb:24-35 combines Claude Code/API with claude.ai, and expects Codex
  CLI/API names in a summary response that currently omits those components.
- runtime/status.rb:166-198 substring-matches component names, falls back to global
  health, reuses global description for scoped states, and keeps only one incident
  matched by title rather than component identity.
- runtime/presenter.rb:1070-1091 turns this into a general provider incident; its
  service tile and QML repeat the ambiguous description.
- runtime/notifications.rb:80-90 compares only aggregate state and can mistake
  restored coverage for recovery or miss a new incident at the same severity.
- runtime/status.rb:127-144 labels failed quota requests as degraded service;
  authorization, account endpoint reachability, and inference health differ.
- runtime/daemon.rb:40-45 refreshes quota before auxiliary status. Preserve the
  existing scheduler for this feature; do not claim an independent status cadence
  or deadline that the current scheduler does not provide.

All source paths above are relative to lib/tokenmaxx/ unless stated otherwise.

## Verified upstream contracts

### OpenAI

- /api/v2/summary.json returns 25 components in the observed response and omits
  the Codex CLI/API entries. Never use its global indicator as Codex health.
- https://status.openai.com/api/v2/components.json returns 37 components and
  explicit statuses, including Codex API 01KMP3KP5MGE23B80K1EK4S8PV and
  CLI 01KMKFAMWKNQ84Z1766MV08ZDE, both operational at observation.
- https://status.openai.com/proxy/openai-1 returns the official website's native
  JSON: full catalog, groups, active incidents, affected_components and
  component_impacts keyed by component_id. The current M365 incident explicitly
  affects Connectors/Apps, not Codex.
- The native route is observed, undocumented website infrastructure, not a
  promised stable public API. Treat it as optional enrichment, independently
  validated and independently fallible. Component health must survive its loss.
- Validate page identity 01JMDK9XYNY6RXSED6SDWW50WY and joins. A similarly named
  endpoint can return HTTP 200 for the wrong page. HTTP success is insufficient.
- Compatibility incidents.json can supply unscoped active context if enrichment
  fails; its observed history/pagination is not a completeness guarantee.

### Claude

- https://status.claude.com/api/v2/summary.json provides current component states
  and incident components[].id. Update affected_components[].code joins to IDs.
- Coding scope: Claude Code yyzkbfz2thpt and Claude API k8w3r06qmzrp.
- claude.ai/Cowork are separate services. An incident affecting them is not proof
  of Claude Code/API impact, nor proof that a shared identity dependency cannot
  affect a user. Present explicit vendor scope, not stronger dependency claims.
- Some incidents have no associations. Retain them as unconfirmed scope.

Do not depend on rendered HTML scraping or undocumented history pagination.
The current-status feature needs current components and active incidents, not a
historical archive. Fetch a bounded detail only when current data needs it.

## Evidence and classification

Maintain two independent dimensions: current component health and incident
lifecycle. Monitoring is not synonymous with current degradation, and past impact
is not proof of current impact. Maintenance is an advisory with its own lifecycle,
not automatically an outage; do not mark a future maintenance as active impact.

Use stable component IDs, validated page identity, and explicit vendor group
membership. Keep reviewed ID/name aliases in metadata; do not adopt arbitrary
components named API, CLI, or Login. Unknown IDs/renames remain observable gaps.

Incident association rules, in order:

1. Explicit current affected-component IDs establish known scope.
2. Historical update/impact associations establish previous membership, not
   necessarily current component health. Preserve both facts separately.
3. Missing associations produce unconfirmed scope, even if the title sounds
   unrelated. Narrow deterministic product-name clues may label possibly related,
   but cannot alone assert confirmed coding impact.
4. Confirmed coding association plus explicit current impact can establish a
   coding incident even when the component catalog is incomplete. Mark coverage
   incomplete; do not manufacture all-service operational coverage.
5. Other-service incidents require explicit evidence of noncoding scope. Never
   call an unassociated incident unrelated merely because it did not match.
6. A single incident can affect coding and other services. Keep one incident ID
   with both memberships, not duplicate independent incident records.

Coding aggregate: worst known outage/degradation wins; otherwise all required
services must have fresh explicit operational evidence for operational. Missing,
unrecognized, invalid, conflicting, or stale required evidence prevents green.
Expose individual service rows so one operational component cannot mask another
unknown component. Vendor-wide state is contextual only.

Conflicting same-scope current evidence is visible as a conflict. Retain confirmed
impact when supported rather than declaring operational; do not let independent
source timestamps disguise an inconsistent refresh as an atomic vendor snapshot.

## Normalized cache contract

Add a versioned status envelope in status.json; preserve snapshot.json as the
only frontend data source. Version the snapshot contract when its semantics change.
Use one canonical normalized record per provider, conceptually:

- state: scoped current state (ok/degraded/outage/unknown), never vendor-global.
- scope, description: explicit product scope and text derived from the same facts.
- coverage: complete/partial/unavailable plus missing required service identities.
- services[]: stable component ID, name, scope, raw and normalized state, evidence.
- incidents[]: stable ID, title, URL, lifecycle, severity, coding/other/unknown
  memberships, current and historical affected IDs, latest vendor update/time.
- vendor: contextual global indicator and source page URL, never copied to state.
- observations: quota/account check outcome, separately labeled from service health.
- sources[]: URL, page identity, kind, attemptedAt, lastSuccessAt, vendorUpdatedAt,
  freshness, parse/HTTP error, and association coverage/completeness.

Keep last-good observations on fetch failure with their original success time.
Never refresh lastSuccessAt on a failed poll or use snapshot generation time as
status freshness. A vendor component updated months ago can still be freshly
checked today. Freshness uses successful retrieval time, not vendor mutation time.
Use the existing status.refreshSeconds: fresh until max(2 * interval, 120 seconds),
then stale. Derive this at presentation time, including when the daemon is stopped;
QML may compare a presenter-provided staleAt timestamp with its clock but must not
classify incidents. Cached CLI/Waybar must also evaluate expiration on read.

Sources fail independently. A missing OpenAI enrichment response must not erase
fresh explicit Codex component health, while the incident list shows unavailable
or incomplete coverage. Do not render an incomplete list as no active incidents.
Retain stale incidents as stale, not perpetually active fresh alerts.

Old unscoped cache versions cannot establish coding impact or recovery. Read them
conservatively as awaiting scoped refresh, preserving quota and unrelated caches.
No user config migration is needed merely to introduce cache fields.

## Account observations for all six providers

Do not break Gemini's model/product attribution or change its source into inference
probing. Apply the common evidence vocabulary without fabricating coverage.
OpenCode Go, Z.ai, and Ollama currently use account endpoints as status signals:
show account check success/error as such; service health is unknown when there is
no public authoritative source. Distinguish HTTP 401/403 authentication/access,
429 account/rate limit, timeout/network, 5xx account endpoint, malformed response.
Do not use them as proof of a provider-wide inference outage. Reuse an observation
already collected in the refresh when it is the same endpoint, credentials, and
freshness; never repurpose a different endpoint or swallow a failed usage result.
Ollama quota and existing balance status checks are not interchangeable by default.

## Existing-surface experience

Overview: separate quota styling from service health. Show a short coding line and,
when needed, a neutral other-incident count or an unconfirmed-scope notice. Opening
it focuses the existing Provider Detail service section. Unknown is not red outage.
Quota warning/critical remains legible alongside service impact.

Provider Detail: replace the ambiguous Service tile with Coding services and
explicit rows for the tracked services. Show last check, coverage/freshness, source
link, and a compact incident section with Affects coding / Other services / Scope
unconfirmed groupings. Mixed-scope incidents appear once with scope chips. Each
incident shows title, lifecycle, affected services, vendor update time, latest
plain-text update, and an accessible incident link. Long updates expand inline;
no unbounded nested page or raw vendor HTML. Account/auth errors remain in a
separate Account check row rather than Provider service outage notes.

Waybar: text remains quota-only. service-degraded/service-outage classes mean
confirmed fresh coding impact only. Tooltip adds scoped status, freshness, and
concise other/unconfirmed incident context. Escape all vendor text for the target
markup format; links are allowlisted HTTPS vendor URLs, never arbitrary payload URLs.

CLI and localhost server: retain status, status --cached, and /status. Output the
structured evidence and scoped summaries through the same normalization. Cached
reads never fetch; explicit status refresh rebuilds snapshot and signals Waybar as
it does today. Do not add a parallel status-only runtime/store.

No new tab or preference screen. Existing incidentWarnings controls confirmed
coding-impact notifications. Other vendor incidents remain visible but silent.

## Notification semantics

Track confirmed incident identity, affected coding components and severity, plus
whether an actionable notification was previously delivered. Notify once for new
confirmed impact and material escalation; coalesce simultaneous impacts into one
provider notification. Body edits and routine polling never notify. An operational
component under monitoring says operational / monitoring, not active degradation.

Notify recovery only after previously notified impact has explicit fresh recovery
evidence (affected coding components operational, or explicit vendor resolution
with no remaining confirmed impact). Losing coverage, failed polls, empty partial
feeds, startup cache migration, or incident disappearance alone is not recovery.
Track partial recovery without claiming all coding services recovered. Respect
provider enabled state and existing master notification setting. No new background
alerts for unrelated connectors, authentication failures, or unavailable feeds.

## Implementation sequence and acceptance gates

1. Source adapters and normalization. Keep runtime/status.rb as orchestration and
   small shared reduction; isolate Claude Statuspage and OpenAI-specific parsing
   in runtime/status/claude.rb and runtime/status/openai.rb. No generic provider
   framework. Metadata keeps scope definitions; adapters own raw schema handling.
   Gate: captured fixtures reproduce today's failures and produce correct scoped
   results; complete component coverage remains useful if enrichment fails.
2. Cache, freshness, presenter, and notifications. Update state/read paths, CLI and
   localhost JSON projections; eliminate legacy global-description and provider-
   status precedence leaks. Gate: cache-to-snapshot-to-tooltip/JSON consistency,
   no false outage, no false recovery, no added quota/status network coupling.
3. Existing QuickShell surfaces and Waybar tooltip. Add per-service evidence and
   incidents in Provider Detail; concise Overview summaries, quota-only chip.
   Gate: real off-desktop panel render/load plus logs, long text, narrow viewport,
   multiple incidents, stale/unknown/partial states, keyboard and accessible links.
   Do not control the user's desktop without explicit authorization.
4. Documentation and shipping proof. Update docs/status.md, runtime-contracts.md,
   docs/ui.md, WIREFRAME.md and relevant README guidance. Run make syntax, make
   test, qmllint, make check, cached CLI/server smoke and live public-feed smoke.
   Do not run credential-dependent check-live unless its prerequisites are met.
   Capture exact source revision for gates. Installation/restart/live-desktop
   verification is a separately authorized delivery step, not assumed by planning.

## Deterministic regression matrix

- Claude coding components operational + M365 claude.ai/Cowork impact: coding ok,
  connector visible separately, no incident styling/notification for coding.
- OpenAI summary lacks Codex; components endpoint explicitly covers it: coding ok.
- OpenAI complete component feed unavailable: coding unknown or stale last-known,
  never vendor-global degraded and never green from absent incidents.
- OpenAI enrichment fails: retain valid component health and mark incident coverage.
- Explicit coding and mixed-scope incidents; generic title with component-ID link;
  missing/null associations; unknown component, duplicate names, wrong-page 200.
- Partial required-component coverage, unknown state enum, conflicting evidence,
  malformed JSON, timeout, HTTP error and source-specific last-good retention.
- Monitoring after components recover, scheduled maintenance, simultaneous coding
  incidents, partial recovery, resolution and disappearing incident under partial
  coverage; deterministic sort by relevance, severity, latest update and stable ID.
- Same-severity new incident notifies once; repeated body edits do not; transient
  unknown and old-cache migration never produce recovery notifications.
- 401/403/429/5xx account endpoint observations never become inference outages.
- Legacy cache, expired source with newly generated snapshot, stopped daemon,
  markup injection, unsafe links, long titles/updates and bounded panel scrolling.
- Cached CLI, localhost request handlers, Waybar and QML make zero network calls.
- Preserve all existing provider quota behavior, history, visibility, pinning,
  config values and compact chip text; no additional supported providers.

## Definition of done

Today both Codex and Claude read vendor-reported coding operational from explicit
component evidence, while M365 connector incidents remain visible as other-service
context. When coding is affected, the user sees exactly which service, what the
vendor says, when it was checked, and one appropriate alert. When evidence is
missing, TokenMaxx says so instead of inventing either an outage or reassurance.
All named acceptance gates must be exercised before implementation is called done.
