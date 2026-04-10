# OpenAI SDKs with apfel

`apfel` exposes a local OpenAI-compatible base URL:

```text
http://localhost:11434/v1
```

Use it with **Chat Completions**, not the newer Responses API. `apfel` implements `POST /v1/chat/completions`, `GET /v1/models`, and `GET /health`. It does **not** implement `POST /v1/responses`.

## Start the local server

Non-browser clients:

```bash
apfel --serve
```

Browser clients on `http://localhost:3000`:

```bash
apfel --serve --cors --allowed-origins "http://localhost:3000"
```

For more security options, see [docs/server-security.md](docs/server-security.md).

## Python

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:11434/v1",
    api_key="ignored",
)

resp = client.chat.completions.create(
    model="apple-foundationmodel",
    messages=[{"role": "user", "content": "Say hello in one word."}],
)

print(resp.choices[0].message.content)
```

## Node.js / TypeScript

```ts
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://127.0.0.1:11434/v1",
  apiKey: "ignored",
});

const resp = await client.chat.completions.create({
  model: "apple-foundationmodel",
  messages: [{ role: "user", content: "Say hello in one word." }],
});

console.log(resp.choices[0]?.message?.content);
```

## Browser `fetch()`

Start `apfel` with `--cors` and an explicit allowlist:

```bash
apfel --serve --cors --allowed-origins "http://localhost:3000"
```

Then call Chat Completions directly:

```js
const resp = await fetch("http://localhost:11434/v1/chat/completions", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    model: "apple-foundationmodel",
    messages: [{ role: "user", content: "Say hello in one word." }],
  }),
});

const data = await resp.json();
console.log(data.choices[0].message.content);
```

## Supported local SDK surface

- `client.chat.completions.create(...)`
- `client.models.list()`
- `stream=True` / streaming Chat Completions
- `tools` and `tool_choice`
- `response_format: {"type": "json_object"}`

## Not supported

- `POST /v1/responses`
- `POST /v1/embeddings`
- `POST /v1/completions`
- image input / multimodal requests

If you hit `501 Not Implemented`, switch the client flow to `POST /v1/chat/completions`.
