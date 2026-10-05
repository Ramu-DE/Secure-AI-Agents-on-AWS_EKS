# 1200 — Agent memory & session persistence

Give agents **memory**: short-term conversation state that survives pod restarts
and reconnects, and long-term semantic memory so a persona's facts/preferences
("I prefer express shipping", "my usual card is the gift card") persist across
sessions.

Builds on:
- **300** — the per-session `session_id` / `user_id` already attached as trace
  attributes. Those same ids key the memory store.
- **500** — the existing **Milvus** instance (used for product RAG) is reused for
  long-term semantic memory in a separate collection. Same embedder
  (`all-MiniLM-L6-v2` via fastembed), so no new infra.
- The specialists are explicitly **stateless** today ("Specialists have no
  memory — they only see what you send them"). This module adds the memory the
  orchestrator can inject.

## Two tiers

```
short-term (per session)   -> DynamoDB  agent_sessions  (pk=session_id)
                              last N turns; TTL 24h; survives restart/reconnect
long-term  (per user)      -> Milvus    agent_memory    (filtered by user_id)
                              salient facts, embedded; semantic recall across sessions
```

- **Short-term** is a rolling transcript window keyed by `session_id`. On each
  turn the agent appends the user/assistant messages and reloads the window —
  so a dropped WebSocket or a rescheduled pod doesn't lose the conversation.
- **Long-term** stores *salient* facts (not whole turns) tagged with `user_id`.
  A `recall_memory(query)` tool does a `user_id`-filtered vector search; a
  `remember(fact)` tool writes one. The agent decides what's worth remembering,
  the same way it decides which tool to call.

## Why DynamoDB for short-term

It's already the datastore in this workshop (orders), the access pattern is a
simple keyed get/put with TTL, and Pod Identity scoping is identical to the
existing `ORDERS_TABLE` grant — minimal new surface. Terraform
(`terraform/memory.tf`) creates `agent_sessions` with `ttl` enabled on an
`expires_at` attribute.

## Wire-in (agent code)

`memory.py` is a drop-in module the single-agent (500) or orchestrator (600)
imports. `build_session_agent(...)` calls `load_session(session_id)` to seed the
Strands `Agent(messages=...)` and registers `recall_memory` / `remember` as
tools. See the inline docstrings — the integration is ~6 lines in `server.py`.

## Apply

```bash
# Terraform exports SESSIONS_TABLE; MILVUS_URI already in agent-config.
kubectl apply -f k8s.yaml       # adds SESSIONS_TABLE to agent-config + RBAC note
kubectl rollout restart deploy/customer-agent
```

## Test

| Case | Expected |
|---|---|
| Ask a question, reconnect (new WebSocket, same session) | prior turns still in context |
| Tell the agent "remember I prefer express shipping", new session next day | `recall_memory` surfaces it; agent uses it |
| Different `user_id` | cannot see the other user's long-term memory (filtered) |

## Files
- `memory.py` — DynamoDB short-term window + Milvus long-term store + the two tools.
- `test_memory.py` — unit tests (mocked DynamoDB + Milvus).
- `k8s.yaml` — adds `SESSIONS_TABLE` to `agent-config`; SA Pod Identity note.

## Production deltas
- Long-term memory is user-scoped by a filter, not row-level security —
  enforce the `user_id` filter server-side (done here), never from a client arg.
- Add a summarization pass when the short-term window exceeds the model's
  context budget (store a running summary + last N verbatim turns).
