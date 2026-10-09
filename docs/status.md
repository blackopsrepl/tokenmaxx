# Status

TokenMaxx tracks two status layers for the supported providers.

Provider health is still derived from quota fetch results:

- successful usage payloads render healthy, warning, or critical classes through the presenter
- provider fetch errors are preserved in snapshots and surfaced through UI/Waybar output
- stale snapshots are detected from `generatedAt` and `runtime.refreshSeconds`

External service status is cached in `status.json`:

- Codex uses OpenAI Status: `https://status.openai.com/api/v2/summary.json`
- Claude uses Claude Status: `https://status.claude.com/api/v2/summary.json`
- Gemini uses Google Cloud incident history: `https://status.cloud.google.com/incidents.json`
- OpenCode uses the OpenCode Go usage endpoint `https://opencode.ai/zen/go/v1/usage` as the service health signal (there is no public OpenCode status page)
- Z.ai uses the Z.ai quota endpoint `https://api.z.ai/api/monitor/usage/quota/limit` as the service health signal (there is no public Z.ai status page)
- Ollama Cloud uses the Ollama balance endpoint `https://ollama.com/api/balance` as the service health signal

Use:

```bash
tokenmaxx status
tokenmaxx status --cached --format json --pretty
```

Waybar and QuickShell consume the cached status through `snapshot.json`; they do not poll status feeds directly.
