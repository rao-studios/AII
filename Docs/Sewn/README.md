# Sewn — the models and the personal layer

[← the stack](../../README.md) · [AII](../AII/README.md) · [Thread](../Thread/README.md) · [Seam](../Seam/README.md)

Sewn is the HTTP and WebSocket half of the Ambient Intelligence Index, run as `AIIServer sewn` on HTTP
47080 and gRPC 47091. It turns a question into an answer grounded in the caller's lane:
- It takes the turn and fetches context from Thread over Seam.
- It runs the model on this Mac (MLX through SinatraHarness and Frigate), or on Mistral or Tinker when
  the home holds that provider's key. No account is needed for either.
- It streams the answer with citations.
- It writes what the turn learned back into the lane.

Sewn stores no vectors and no graph. Thread holds the index; Sewn holds the conversation, the models,
accounts and attribution. It is built on Hummingbird 2.

![A turn through Sewn in six steps: 1 Admit, where the secret names your app and with no bearer the owner is local-app and no account is needed; 2 Retrieve, where Seam fans the last message out to Thread stamped with your lane; 3 Compose, with your passages framed as "you wrote", the recap, a persona and citations; 4 Generate, on device through SinatraHarness, or Mistral with a key; 5 Stream, server-sent events with references, tokens, contribution and Sinatra diagnostics; 6 Write back, where memories, resonant passages and the recap go back into your lane. A dashed gold loop runs from step 6 back to step 2: the next turn retrieves what this one wrote. Below, your lane with your documents and the memory, resonance and recap groups, and SinatraHarness, a small net per person. A legend marks what is live today and what is planned.](../README_Assets/sewn-turn.png)

## The personal layer

Most assistants personalize by sending a person's history to a hosted model. In AII, personal context
is a lane of an on-device index that every app on the Mac shares, and each app can only read its own
lane. Four things make a turn personal today:

- **Context from the person's own lane.** Every chat turn retrieves from the caller's lane in Thread,
  scoped to an owner and optionally to groups. The person's passages are framed as "you wrote …", and
  other owners' passages go inside `<external>`. It is graph and vector search over what this person
  and this app deposited, not over a shared corpus.
- **It writes back.** Every 7th message, or at a session boundary, Sewn summarizes the conversation into
  the app's `<app>-memory-<owner>` group. A passage the person resonated with lands in
  `<app>-resonance-<owner>`. With `"recap": true` a running recap ledger is kept in the lane too. All
  three are ordinary documents, so the next turn retrieves them. The index becomes the person's memory.
  The groups carry the app's name because a group belongs to the first lane that files into it, and
  apps may share an owner. A caller that is no app (an open, hosted Sewn) keeps `memory-<owner>` and
  `resonance-<owner>`.
- **In the schema every app files.** Each write-back is the document `<app>/memory/<id>`, with an
  `aii-record/1` envelope of kind `memory` as its metadata and the source kind `sewn-summary`,
  `sewn-resonance` or `sewn-recap`. `AIIInstance.recall` returns them like any record of the app's own,
  and `forgetMemory()` deletes the memory and resonance groups
  ([AII → The record](../AII/README.md#the-record)).
- **A per-person steer, on device.** With `provider: local`, SinatraHarness encodes the retrieved
  passages with the model's own embedding table. A small per-person network (SinatraNet, about 2k
  parameters) weighs them into a sparse logit bias before sampling. It learns from grounding: each
  answer is scored with and without its context, which measures which passages actually shaped it.
  The model's weights never change, there is no fine-tuning, and the turn runs under
  `VendorEgress.refusing`, so nothing leaves the Mac.
- **Personas.** The stored personalities are `sewn`, `scholar` (temperature 0.3) and `muse` (0.9).
  An inline `persona` sets a name, a voice and the person's name.

Planned, not live:
- **Marielle**, the proactive layer, answers 503 today. Its routes are open, proactive, interject and
  bridge (an ice-breaker, "is there anything to say?", a lateral question mid-session, a bridge
  between two people). Its prompts and scoring are in place.
- **The server-side Sinatra model** (gradient-boosted trees over sentiment and engagement) trains on
  every hosted turn, but nothing applies its output yet. Every turn samples at the base tone
  (temperature 0.4, top_p 0.9).

**Attribution (Gita)** runs on every turn. The model cites with `[[n]]` markers, which Sewn strips and
resolves into character spans. Each document's share of the answer is priced against the turn's real
token cost. It arrives as `contribution`, and `GET /v1/wallet` holds the earnings.

## Integrate

For one question at a time, `AIIInstance.ask` does all of this for you ([AII → Join](../AII/README.md#join)).
This section is the route underneath. Set up the dependency and the supervisor first
([AII → The long way](../AII/README.md#the-long-way)).
To retrieve anything, your lane needs documents; see [Thread → Deposit](../Thread/README.md#deposit).

### Chat with no account

Your app's secret is enough. With no `Authorization` header, Sewn admits the call and runs it on device,
or on a hosted provider whose key the home holds (`~/.rao/keys/providers.json`, set by `aii setup` or
`aii keys set`). Naming no provider picks the server default when its key is there, else the one hosted
provider with a key, else on device; naming a hosted provider without its key answers 503. It answers as the lane's owner in
the lanes manifest: `local-<app>`, the app's own, or `aii-local` once the app opts in to the owner
Ambient, Craft and Veil share ([AII → Owners](../AII/README.md#owners)). Sewn reads the manifest
again when it changes, so a new owner takes effect without a restart.

```swift
import AII
import Foundation

/// One streamed turn on this Mac, grounded in the app's lane.
func ask(_ question: String, app: AIIApp = "notes", home: AIIHome = .resolved()) async throws -> String {
    let port = AIIConfig.load(home: home).sewnPorts.http                    // 47080
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(try home.readSecret(for: app), forHTTPHeaderField: StackSecret.headerName)
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "messages": [["role": "user", "content": question]],
        "provider": "local",                                              // on device; nothing leaves the Mac
        "stream": true,
        "max_tokens": 512,                                                // the default is 128
        // owner_id is required; with no account Sewn answers as the lane's owner whatever it says.
        "sewn": ["owner_id": (home.lane(app)?.owner ?? .app(app)).rawValue, "scope": "personal", "aggregate": true] as [String: Any],
    ] as [String: Any])

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    var answer = ""
    for try await line in bytes.lines where line.hasPrefix("data: ") {
        let payload = line.dropFirst(6)
        if payload == "[DONE]" { break }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
        if let failure = chunk.error { throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: failure.message]) }
        answer += chunk.choices?.first?.delta?.content ?? ""
    }
    return answer
}

struct Chunk: Decodable {
    struct Choice: Decodable { struct Delta: Decodable { var content: String? }; var delta: Delta? }
    struct Reference: Decodable { var id: String }                       // also partition_id, owner_id, thread_id
    struct Failure: Decodable { var message: String }
    var choices: [Choice]?
    var references: [Reference]?                                          // on the first chunk: what the answer may cite
    var error: Failure?
}
```

The same turn from a shell:

```sh
curl -N localhost:47080/v1/chat/completions \
     -H "X-Ambient-Secret: $(cat ~/.rao/secrets/notes)" -H 'Content-Type: application/json' \
     -d '{"messages": [{"role": "user", "content": "Who leads Joltvault?"}],
          "provider": "local", "stream": true, "max_tokens": 512,
          "sewn": {"owner_id": "local-notes", "scope": "personal", "aggregate": true}}'
```

The stream sends a role chunk with `references` first, then `delta.content` chunks. Next come
trailing chunks with empty `choices`, carrying `contribution` and, on device, `sinatra` diagnostics.
It ends with `data: [DONE]`. An error after the 200 arrives as `data: {"error": {…}}` with no `[DONE]`.

### Pick and fetch the on-device model

`AIIClient` speaks the provider routes for you:

```swift
let client = AIIClient(app: "notes")
for model in try await client.models() { print(model.id, model.disk) }   // every pinned model: absent, downloading, installed
try await client.download(model: AIIModels.generalLarge.id)              // fetch at its pinned commit
try await client.warm(model: AIIModels.generalLarge.id)                  // make it this Mac's chat model and load it
```

The default is `AIIModels.generalStandard` (Mistral-Nemo). The last model warmed, or named on a
valid local request, becomes the Mac's on-device model for every app, because one Sewn serves the
Mac. `GET /v1/providers` lists each provider's availability and state.

### Signed in: an app with accounts

An app that ships accounts (see the README's "Shipping with accounts") signs its people in:
`POST /v1/auth/sign-in` with `{"email", "password"}` returns `{access_token, refresh_token, expires_in,
user_id}`. Send `Authorization: Bearer <access_token>` beside the secret. The owner then becomes the
user's id, and the user's lane documents are the ones filed under that id. Providers follow the same
keys either way.

### Other routes an app uses

| Route | No account | Does |
| --- | --- | --- |
| `POST /v1/complete` | ✓ | one bounded completion: `{instructions?, messages, max_tokens? (32–2048, default 256), temperature?, provider?, model?}` → `{text}`; no persona, no retrieval |
| `POST /v1/skills/complete`, `/v1/code/complete` | | the same with `tools` → `{text, tool_calls?}`; code pins the coding model |
| `POST /v1/vision/look` | ✓ | a picture (base64) and a mode → `{text}`; on device in its own vision slot |
| `POST /v1/vision/ontology` | ✓ | a picture → `{caption, tags, entities, relationships}`, ready to deposit into Thread |
| `GET /v1/realtime/chat` | | a WebSocket voice turn: `turn.start` with a chat request, then tokens, PCM audio and `turn.end` |
| `POST /v1/search`, `/v1/graph`, `/v1/embeddings` | | search, graph and ingest through Sewn's fan-out (an app on the Mac can call Thread directly instead) |
| `GET /v1/threads`, `/v1/stats` | ✓ | the Thread nodes Sewn knows; the caller's lane counts |

## What `/v1/chat/completions` takes

The route and its core shapes follow OpenAI's, but it is not a drop-in replacement:
- **`sewn` is required.** It holds `owner_id`, `scope` (`personal` or `global`), `aggregate`, and
  optionally `group`/`groups`. Send `scope` explicitly, because an omitted scope searches as `global`.
  `owner_id` must be there, but Sewn answers as the caller it authenticated: the signed-in user, or
  with no account the lane's owner in the manifest.
- **Roles** are `user`, `assistant` and `system`. There is no `tools`, `n` or `response_format`, and
  `stop` is ignored.
- **`max_tokens` defaults to 128.** Thinking models get a floor of 4096.
- **Only the last user message is the retrieval query.** The model sees a rebuilt prompt: context,
  recap, then history. A hosted turn that retrieved nothing gets no history. A local one gets the last 10
  turns.
- **The response adds keys:** `references`, `contribution`, `auto_memory` (true means the client may drop
  its history), `tone`, `personality` and, on device, `sinatra`. The model is echoed as `api-<model>`.
- **Further keys:**
  - `temperature`, `top_p`, `repetition_penalty`, `kv_bits`
  - `persona {name, voice, user_name}`, `personality`, `instructions`
  - `recap` and `recap_reset`
  - `sinatra {mode: lexical|dense|off, trace, seed, record}`
  - `model`: on device, an `org/repo[@rev]` id

## Providers

| `provider` | Runs | Needs |
| --- | --- | --- |
| `local` | MLX in process through SinatraHarness: the chat model and a separate vision slot | `mlx.metallib` beside `AIIServer`; the model on disk |
| `mistral` | Mistral's API (`mistral-large-4` by default) | the Mistral key in `keys/providers.json` |
| `tinker` | Thinking Machines (`Inkling-Small`) | the Tinker key in `keys/providers.json` |

Only the `provider` field chooses the provider; a model name never does. When it is omitted, a
signed-in caller gets the server default (`SEWN_GLOBAL_LLM`, else `mistral`); a caller with no account
gets the server default when its key is present, else the one hosted provider with a key, else `local`.
A hosted provider without its key answers 503. `/v1/embed`, `/v1/speak` and the vision routes' hosted
path always use Mistral.

## Routes

| | |
| --- | --- |
| Open | `GET /health` (the launcher's challenge), `GET /v1/stats`, `GET /v1/threads`, `POST /v1/auth/{sign-in, sign-up, verify, refresh, reset-password, resend}` |
| Generation | `POST /v1/chat/completions` ✓, `/v1/complete` ✓, `/v1/skills/complete`, `/v1/code/complete`, `/v1/vision/look` ✓, `/v1/vision/ontology` ✓, `/v1/tools/summarize`, `/v1/speak`, `GET /v1/realtime/chat` (WebSocket) |
| Index | `POST /v1/embeddings`, `/v1/embed`, `/v1/search`, `/v1/graph` |
| Library | `POST /v1/list/{documents, groups, groups/documents}`, `/v1/modify`, `/v1/modify/group/{access, remove, metadata}` |
| Providers | `GET /v1/providers` ✓, `POST /v1/providers/local/{warm, download, remove}` ✓, `GET /v1/providers/local/models` ✓, `GET /v1/providers/local/sinatra/{traces/:id, analysis}` ✓ |
| Account | `POST /v1/auth/{sign-out, update-password}`, `GET /v1/account/{keys, plan}`, `/v1/account/rao-verified/keys`, `GET`/`PATCH /v1/profile`, `GET /v1/wallet`, `POST /v1/feedback`, `GET /v1/personalities` |
| Discovery | `GET /v1/infinite/leaderboard`, `POST /v1/infinite/search` (public groups ranked by earnings, retrievals and sentiment) |
| Debug | `POST /v1/frank/{gbt, parking, reset, export, import}` (Sinatra state); `/v1/admin/*` behind `ADMIN_USER_ID` |
| Planned | `POST /v1/marielle/{open, proactive, interject, bridge}`, which answer 503 |

✓ marks the routes a local app reaches with its secret and no account. The stack identity (the `aii`
command) reaches only the routes it manages models with, as owner `aii-local`: `GET /v1/providers`,
`GET /v1/providers/local/models` and `POST /v1/providers/local/{download, remove}`. It never chats.

On a local stack (`AII_HOME` set, as the supervisor runs it), every route except `/health` needs
`X-Ambient-Secret` and a loopback host. The answers are 401 and 421 otherwise. Without `AII_HOME`,
Sewn is open and answers CORS instead.

## Configuration and running alone

Nothing needs setting: the defaults are the ones the supervisor launches Ambient's stack with. The keys
come from `~/.rao/keys/providers.json` (written by `aii setup`, `aii keys` or an app's Settings), read on
every call. Everything else is reference. First wins: the process environment, then `aii/aii.env` when
a launcher set `AII_HOME` (the two Supabase values only), then `./.env` in Sewn's working directory.

| Variable | |
| --- | --- |
| `MISTRAL_API_KEY`, `TINKER_API_KEY` | the hosted providers; from `keys/providers.json` on a stack, else the environment; a request for a provider without its key answers 503 |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | the accounts layer, for apps that ship accounts; without them the auth routes answer 503 |
| `ADMIN_USER_ID` | a hosted Sewn's one admin account; unset, every `/v1/admin/*` route answers 403 |
| `METRICS_TOKEN` | guards `GET /metrics`, registered only with `--server-mode` |
| `SEWN_DATA_DIR` | the storage root after `--data-dir`; `AII_HOME/aii/sewn/db` on a stack, else `~/Documents/sewn-db` |
| `SEWN_GLOBAL_LLM` | the server default provider (`mistral` when unset) |
| `SEWN_LOCAL_MODEL`, `SEWN_LOCAL_VISION_MODEL`, `SEWN_LOCAL_VISION_IDLE_SECONDS` | on-device defaults (the vision slot unloads after 300 s idle) |
| `SEWN_CHAT_MODEL`, `UTILITY_MODEL`, `SEWN_CODING_MODEL`, `SEWN_LOCAL_CODING_MODEL`, `TINKER_MODEL`, `VISION_MODEL`, `SEWN_REALTIME_OPENING_MODEL` | hosted and coding models |
| `SEWN_SINATRA_MODE`, `SEWN_SINATRA_TRACE`, `SEWN_SINATRA_ALPHA` | SinatraHarness defaults |
| `SEWN_LOCAL_UTILITY` | `1` lets server-side Sinatra follow local turns on device |
| `SEWN_RECAP_MAX_TOKENS` | the recap's budget (600) |
| `SEWN_REGION`, `THREAD_HOST_OVERRIDE` | a hosted deployment's metric label; the host a registering Thread is rewritten to (Docker) |

```sh
AIIServer sewn --host 127.0.0.1 --port 47080 --grpc-port 47091 --data-dir /tmp/sewn
AIIServer probe chat --app ambient --token "$SEWN_TOKEN" "Who leads Joltvault?"   # the chat wire from a terminal (signed in)
Scripts/test-local-sinatra.sh                                 # the live on-device suite
```

[Skills](Skills/README.md) go deeper: Chat, Providers, Sinatra, Gita, Realtime, Graph, Thread, Seam,
Marielle (the plan), Caching, Concurrency, ProductionReadiness, TestMaintenance, and the
SystemReference (architecture, routes, data models).
