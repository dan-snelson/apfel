# Server Security

apfel's HTTP server (`--serve`) runs on localhost by default and is designed for local development and on-device inference. This document explains the security settings, their reasoning, and how to configure them.

## Why origin checking?

Any website you visit can make HTTP requests to `localhost` via JavaScript. This is called **localhost CSRF** (Cross-Site Request Forgery) - a well-known attack class that has already affected:

- **Ollama** - same port (11434), CSRF via `fetch()`, no auth. [Writeup](https://blog.jaisal.dev/articles/oh-llama)
- **Jupyter** - added token auth after CSRF CVEs. [Security release](https://blog.jupyter.org/security-release-jupyter-notebook-4-3-1-808e1f3bb5e2)
- **175,000+ exposed Ollama instances** found by Shodan. [Cisco](https://blogs.cisco.com/security/detecting-exposed-llm-servers-shodan-case-study-on-ollama)

Without protection, a malicious website could silently use your Apple Intelligence model for compute abuse or exfiltrate responses.

## Default behavior

```bash
apfel --serve
```

By default, apfel checks the `Origin` header on incoming requests:

- **No `Origin` header** - allowed. curl, Python SDKs, scripts, and other non-browser clients don't send this header. Everything works exactly as before.
- **Localhost `Origin`** - allowed. `http://127.0.0.1`, `http://localhost`, `http://[::1]` (with any port) are all permitted.
- **Foreign `Origin`** - rejected with HTTP 403. A website at `http://evil.com` cannot access your server.

This check is invisible to normal usage. If you use curl, the OpenAI Python SDK, or any command-line tool, nothing changes.

## Security flags

### `--allowed-origins <origins>`

Comma-separated list of allowed origins beyond the localhost defaults.

```bash
# Allow a local dev server
apfel --serve --allowed-origins "http://localhost:3000"

# Allow multiple origins
apfel --serve --allowed-origins "http://localhost:3000,http://localhost:5173"

# Allow a specific domain (for non-localhost setups)
apfel --serve --allowed-origins "http://myapp.local:8080"
```

**Default:** `http://127.0.0.1,http://localhost,http://[::1]`

**How matching works:**
- Exact match: `http://localhost` matches `http://localhost`
- Port variants: `http://localhost` in the list also matches `http://localhost:3000`, `http://localhost:5173`, etc.
- HTTPS variants: `http://localhost` in the list also matches `https://localhost`
- Subdomain protection: `http://localhost` does NOT match `http://localhost.evil.com`

### `--no-origin-check`

Disable origin checking entirely. All origins are allowed.

```bash
apfel --serve --no-origin-check
```

**When to use:** Trusted networks, development environments where you need any origin to connect.

**Equivalent to:** `--allowed-origins "*"`

### `--token <secret>`

Require Bearer token authentication on all endpoints except `/health`.

```bash
apfel --serve --token "my-secret-token"
```

Clients must include the token in every request:

```bash
curl -H "Authorization: Bearer my-secret-token" http://localhost:11434/v1/models
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:11434/v1", api_key="my-secret-token")
```

**Note:** `/health` is exempt from token auth so monitoring tools continue to work.

### `--token-auto`

Generate a random token and print it on startup. Same as `--token` but you don't have to invent a secret.

```bash
apfel --serve --token-auto
# Prints: token: 8A3F2B1C-...
```

Explicit secrets passed with `--token` or `APFEL_TOKEN` are not echoed back to the terminal.

### `APFEL_TOKEN` environment variable

Set the token via environment variable instead of a flag.

```bash
export APFEL_TOKEN="my-secret-token"
apfel --serve
```

The `--token` flag overrides the environment variable.

### `--cors`

Enable CORS (Cross-Origin Resource Sharing) headers for browser clients.

```bash
apfel --serve --cors
```

Without `--cors`, browser JavaScript cannot read responses from the server (even if origin check passes). With `--cors`, the server adds `Access-Control-Allow-Origin` to responses.

**CORS + origin check interaction:**
- `--cors` alone: CORS headers reflect the actual allowed origin (not wildcard `*`), so only localhost origins can read responses.
- `--cors --allowed-origins "http://localhost:3000"`: Only that specific origin gets CORS access.
- `--cors --no-origin-check`: Wildcard `*` - any origin can read responses.

### `--footgun`

The nuclear option. Disables all protections: no origin check + CORS enabled.

```bash
apfel --serve --footgun
```

**Equivalent to:** `--no-origin-check --cors`

This is the old behavior before CSRF protection was added. The server prints a prominent warning:

```
WARNING: --footgun mode - no origin check + CORS enabled
Any website can access this server and read responses!
```

**When to use:** Testing, demos, environments where you explicitly want zero restrictions.

## Common scenarios

### Local web app development

Your React/Vite/Next.js app runs on `localhost:3000` and needs to call apfel:

```bash
apfel --serve --cors --allowed-origins "http://localhost:3000"
```

### Shared machine / multi-user

Multiple users or processes need access, and you want basic auth:

```bash
apfel --serve --token-auto
```

Share the printed token with authorized users.

### Quick demo / testing

You want maximum openness for a short demo session:

```bash
apfel --serve --footgun
```

### Production-like (locked down)

Specific origin, token auth, everything restricted:

```bash
apfel --serve --cors --allowed-origins "http://localhost:3000" --token "$(openssl rand -hex 16)"
```

### Old behavior (pre-0.6.21)

Before CSRF protection was added, `apfel --serve` accepted all origins:

```bash
# Exact equivalent of old default behavior:
apfel --serve --no-origin-check

# Exact equivalent of old --cors behavior:
apfel --serve --footgun
```

## Flag interaction matrix

| Flags | Origin check | CORS headers | Who can access |
|-------|-------------|-------------|----------------|
| (default) | localhost only | none | curl, SDKs, localhost browsers (no read) |
| `--cors` | localhost only | allowed origin | curl, SDKs, localhost browsers (can read) |
| `--no-origin-check` | disabled | none | everyone (browsers can't read) |
| `--footgun` | disabled | `*` | everyone (browsers can read) |
| `--token X` | localhost only | none | only with valid token |
| `--cors --allowed-origins X` | custom list | allowed origin | custom origins only |

## Severity assessment

**Low.** Apple's on-device model cannot access the filesystem, network, or any system resources. The worst case from a localhost CSRF attack is:

- **Compute abuse** - a website could use your GPU/NPU for inference
- **Response exfiltration** - with `--cors` enabled, a website could read model responses

Still worth fixing - it's the right default, and it's what every other localhost LLM server has had to learn the hard way.
