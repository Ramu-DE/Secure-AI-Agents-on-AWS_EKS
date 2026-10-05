# 1400 — Resilience, rate-limiting & cost controls

Protect the platform (and the bill) at the gateway: per-persona **rate limits**
and **token budgets**, **retries with backoff**, **circuit breaking / outlier
detection**, request **timeouts**, and a **fallback model** when the primary is
throttled or down.

Builds on:
- The **Envoy AI Gateway** that already fronts Bedrock for every agent, and the
  **agentgateway** that fronts MCP/A2A. Both are policy-driven, so this module
  is mostly declarative config — no agent code change.
- The failure modes already visible in the agent prompts: models looping on
  retries, tools being called repeatedly "hoping for a different result". We move
  those controls to the infrastructure where they belong.

## Controls

| Control | Where | What it does |
|---|---|---|
| Rate limit (RPM) | Envoy AI Gateway | caps requests/min per persona (`x-persona` from JWT) |
| Token budget | Envoy AI Gateway | caps **tokens**/day per persona (usage-based, via `llmRequestCost`) |
| Retry + backoff | Envoy / agentgateway | retry 429/503 with exponential backoff, capped attempts |
| Timeout | HTTPRoute | per-request deadline so a hung upstream can't pin a worker |
| Circuit breaking | Backend | connection/pending caps; shed load instead of collapsing |
| Outlier detection | Backend | eject an unhealthy Bedrock endpoint from rotation |
| Model fallback | AI Gateway route | on primary failure, route to a cheaper/secondary model |

## Why token-budget (not just RPM)

LLM cost is driven by **tokens**, not request count — one request can be 100 or
100k tokens. Envoy AI Gateway's `llmRequestCost` extracts token usage from the
response and feeds the rate-limit service, so the budget is denominated in the
thing that actually costs money. Sales-analyst (runs code, big contexts) and
support-associate get different daily budgets.

## Apply

```bash
# Rate limits + token budgets (Envoy AI Gateway + rate-limit service):
kubectl apply -f policies/aigw-ratelimit.yaml

# Resilience on the Bedrock backend (retries, timeouts, circuit breaking,
# outlier detection) + the fallback route:
kubectl apply -f policies/backend-resilience.yaml
```

## Test

| Case | Expected |
|---|---|
| Exceed RPM for a persona | further calls get `429` until the window resets |
| Burn the daily token budget | `429` with a budget-exceeded message; resets next day |
| Primary model returns 503 | request transparently retried, then falls back to secondary model |
| Hung upstream | request times out at the route deadline, not indefinitely |

```bash
# hammer the endpoint to trip the limit
for i in $(seq 1 100); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1/chat/completions \
    -H 'content-type: application/json' -H 'x-persona: sales-analyst' \
    -d '{"model":"nova-lite","messages":[{"role":"user","content":"hi"}]}'
done | sort | uniq -c      # expect a mix of 200 then 429
```

## Files
- `policies/aigw-ratelimit.yaml` — `BackendTrafficPolicy` RPM + `llmRequestCost`
  token budget, keyed by the `x-persona` header derived from the JWT.
- `policies/backend-resilience.yaml` — retries/backoff, timeouts, circuit
  breaking, outlier detection on the Bedrock `Backend`, plus the fallback route.

## Production deltas
- Rate-limit state needs a shared store (Redis) for the Envoy rate-limit service
  across replicas — single-replica in-memory is dev-only.
- Set budgets from real cost data; alert at 80% before hard-capping at 100%.
- Fallback model should be *cheaper and safe*, not just "any other model" —
  document the quality tradeoff for participants.
