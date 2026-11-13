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
- **Gemini:** the existing Google Cloud product-scoped incident feed at
  `https://status.cloud.google.com/incidents.json`; this is product incident
  evidence, not an end-to-end Gemini CLI inference check.
- **OpenCode Go, Z.ai, Ollama Cloud:** their authenticated account endpoints provide
  account checks, not inference health. Authorization errors, rate limits, and
  account endpoint failures do not become vendor-wide coding outages.

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

Quota warnings remain quota-driven. Overview presents a concise scoped service
summary and other-incident context. Provider Detail shows per-service evidence,
coverage, account checks, and expandable incident updates. The Waybar chip stays
quota-only; its tooltip explains scoped status. Service alert classes are reserved
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
presentation; QuickShell may compare a supplied expiration time with its clock,
but does not classify incidents or infer vendor health.
