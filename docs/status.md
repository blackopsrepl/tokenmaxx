# Status

TokenMaxx separates vendor-reported service health, other provider incidents, and
this installation's account/quota checks. A connector outage is real, but does not
establish that coding services are down. Successful account access does not prove
that inference requests work.

## Coding service scope

- **Codex:** Codex API and CLI, using explicit component identities from
  `https://status.openai.com/api/v2/components.json`. OpenAI's summary response can
  omit Codex; the global OpenAI indicator is never used as Codex health.
- **Claude:** Claude Code and Claude API, using
  `https://status.claude.com/api/v2/summary.json`. claude.ai and Cowork incidents
  are shown separately unless the vendor explicitly associates coding impact.
- **Gemini:** Vertex Gemini API and Gemini Code Assist in the Google Cloud incident
  feed at `https://status.cloud.google.com/incidents.json`. The feed carries every
  incident Google publishes per product, so a tracked product with no active
  incident is operational, as on Google's own status page. Incidents on other
  Gemini-branded products (Gemini Enterprise and the like) are other services;
  incidents on unrelated Google Cloud products are ignored.
- **OpenCode Go:** the Inference API gateway and the Go plan, from OpenCode's
  documented public status JSON at `https://status.opencode.ai/api/status`. Console
  API, Request logs, Pay-as-you-go and Free inference are other services. Only
  unresolved incidents are active, and a payload the vendor marks `stale` is not
  fresh health.
- **Z.ai, Ollama Cloud:** neither vendor publishes a status page, so the panel
  says `No status page`. Their authenticated account endpoints provide account
  checks only; authorization errors, rate limits, and account endpoint failures
  do not become coding outages.

## One alert scale

Every vendor vocabulary maps onto the same four levels, so a colour means the same
thing on every card, in the Waybar classes and in notifications:

| Level | Colour | Statuspage (Codex, Claude) | Google Cloud (Gemini) | OpenCode |
|---|---|---|---|---|
| ok | green | `operational` | `AVAILABLE`, `SERVICE_INFORMATION` | `operational` |
| degraded | amber | `degraded_performance`, `partial_outage`, `under_maintenance` | `SERVICE_DISRUPTION` | `degraded` |
| outage | red | `major_outage` | `SERVICE_OUTAGE` | `outage` |
| unknown | grey | missing, stale or unavailable evidence | same | same |

Amber means some requests fail or run slow; red means most or all fail. Labels keep
the vendor's wording inside a level (`Partial outage`, `Maintenance`). An active
incident the vendor ties to no component is amber context, never dropped and never
red. Z.ai and Ollama Cloud publish no status page and read `No status page` in grey.

OpenAI's official website JSON at `https://status.openai.com/proxy/openai-1`
supplements component health with incident associations. This is an undocumented
website endpoint: its failure reduces incident coverage without discarding valid
component health. All status payloads are validated, including page identity.

## Incidents and uncertainty

Incidents retain stable identities, vendor updates, links, lifecycle and affected
services. Explicit component relationships determine scope:

- **Affects coding:** known coding-service membership.
- **Other services:** explicitly associated noncoding services.
- **Scope unconfirmed:** missing or ambiguous associations; never silently unrelated.
- Mixed-scope incidents remain one incident with both memberships.

Current component health and incident lifecycle are separate. Monitoring can remain
visible after components recover. Conflicting current impact remains visible;
polling one source later does not silently override another source's still-fresh
impact. An older status transition may be superseded by a later vendor-recorded
component change, not merely by a newer local retrieval. Missing components, unknown states, malformed
responses, and incomplete feeds never imply operational service. All required
coding components need fresh explicit operational evidence before showing green.

Quota warnings remain quota-driven. Overview shows one status line: coding health,
then an amber or red notice naming the non-coding services (connectors, web apps)
while they have an active incident; coding health then reads `Coding operational`,
so nothing reads as an all-clear while a vendor service is impacted. Provider Detail shows a Coding services tile and, only
during such an incident, an Other services tile naming what is affected. The full
evidence (per-service records, sources, incidents, account checks) stays in
`status.json` and `tokenmaxx status --json`. The Waybar chip stays quota-only; its
tooltip adds the same one-line status. Service alert classes are reserved
for confirmed fresh coding impact.

## Cache and freshness

`status.json` uses status schema version 2, embedded in snapshot version 4.
Successful retrieval time, fetch-attempt time, and vendor-update time are distinct.
Failed polls preserve last-good observations with their original age. Evidence
becomes stale after `max(2 * status.refreshSeconds, 120)` seconds, including on
cached reads. Snapshot regeneration does not renew service evidence.

Old unscoped caches wait for a scoped refresh; they cannot establish coding impact
or recovery. Individual source failures are preserved so component health can be
available while incident details are unavailable. No model requests are issued to
probe inference health.

Notifications obey the existing master setting and `incidentWarnings`. Only
confirmed coding impact alerts; new incident identity and material escalation are
meaningful changes. Repeated polls, wording edits, unrelated connectors, account
errors and unavailable feeds do not alert. Recovery requires fresh explicit
recovery evidence after previously notified impact, never disappearance from an
incomplete feed.

## Commands and ownership

```bash
tokenmaxx status
tokenmaxx status --cached --format json --pretty
```

Explicit status refresh updates the cache, rebuilds the snapshot, and signals
Waybar. `--cached`, Waybar rendering, QuickShell and localhost `/status` and `/usage`
read cached evidence only. They do not poll providers. Ruby owns normalization and
presentation; QuickShell renders the presenter's status text and state and does
not classify incidents, evaluate expiration, or infer vendor health.
