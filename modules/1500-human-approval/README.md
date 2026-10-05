# 1500 — Human-in-the-loop approvals for high-impact tool calls

Make the agent **pause and ask a human** before executing high-impact actions
(a return/refund, a coding-agent PR merge), instead of running them
autonomously. The agent proposes; a human approves or rejects; only then does
the action execute.

Builds on:
- **500/700** — the mutating tools (`initiate_return`) and their per-persona
  authz. Approval is the next gate *after* authz: "allowed to request" ≠
  "allowed to execute unattended".
- **1000** — the autonomous coding agent opens PRs with no human in the loop;
  the same approval primitive can gate a merge.

## Flow

```
agent calls a GATED tool
   -> approval-service: create request {id, action, args, persona, status=PENDING}
   -> tool returns to the agent: "approval ARQ-123 pending" (NOT executed)
reviewer opens the approvals UI (or GET /pending), approves/rejects ARQ-123
   -> on APPROVE: approval-service executes the real action, status=APPROVED
   -> on REJECT:  status=REJECTED, nothing executes
agent (next turn / poll) sees the resolution and tells the customer
```

The gated tool is a thin wrapper: it does NOT perform the action, it files an
approval request and returns the id. Execution happens in the approval-service
*after* a human decision — so even a jailbroken agent cannot self-approve.

## Why a separate service

- **Separation of authority**: the thing that executes the action is not the
  thing the LLM controls. The agent can only *request*; the service, gated by a
  human, *executes*. This is the core safety property.
- **Durable + async**: approvals outlive a single agent turn (a human may take
  minutes). Requests persist in DynamoDB with a TTL.
- **Auditable**: every high-impact action has a record of who approved it and
  when.

## Components

- `approval-service/service.py` — FastAPI: `POST /requests` (agent files one),
  `GET /pending` (reviewer lists), `POST /requests/{id}/approve|reject`
  (reviewer decides; approve triggers execution). DynamoDB-backed.
- `approval-service/gated_tool.py` — the Strands tool wrapper agents import:
  `make_gated_tool("initiate_return", ...)` files a request instead of acting.
- `k8s.yaml` — Deployment + Service + RBAC/Pod-Identity note.

## Apply

```bash
kubectl apply -f k8s.yaml
# point the agent at it:
kubectl set env deploy/customer-agent \
  APPROVAL_SERVICE_URL=http://approval-service.default.svc.cluster.local:8080
kubectl rollout restart deploy/customer-agent
```

## Test

| Case | Expected |
|---|---|
| Support agent initiates a return | agent replies "pending approval ARQ-…", nothing executed yet |
| Reviewer `POST /requests/{id}/approve` | the return executes; status APPROVED; customer told it's done |
| Reviewer rejects | status REJECTED; no return created; customer told it was declined |
| Agent tries to approve its own request | not possible — no self-approve endpoint reachable by the agent SA |

```bash
# simulate a reviewer
curl -s localhost:8080/pending
curl -s -X POST localhost:8080/requests/ARQ-123/approve
```

## Files
- `approval-service/service.py`, `gated_tool.py`, `requirements.txt`, `Dockerfile`
- `test_service.py` — unit tests for the approve/reject state machine (mock store).
- `k8s.yaml`

## Production deltas
- Authenticate reviewers (Cognito, a `reviewer` group) and record the approver
  identity on the request — the stub trusts the caller.
- Notify reviewers (Slack/email/UI toast) instead of polling `/pending`.
- Add an expiry policy: auto-reject requests not actioned within N minutes.
