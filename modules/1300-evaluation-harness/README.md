# 1300 — Evaluation & regression harness (LLM-as-judge)

Turn "it seemed to work in the demo" into a **repeatable, scored test suite**.
Replay persona scenarios against the deployed agent, grade each answer with an
LLM judge on explicit rubrics, and fail CI if quality regresses.

Builds on:
- **300** — the eval reads Langfuse traces to assert on *tool selection* and
  *latency*, not just the final text.
- **500/700** — scenarios include **authz-negative** cases: a sales-analyst
  asking for a support-only action (`initiate_return`) MUST be refused. The judge
  scores refusal correctness, catching regressions where a prompt tweak makes the
  agent leak a capability.
- The existing `test_server_events.py` unit tests check plumbing; this checks
  *behavior*.

## What it measures (per scenario)

| Dimension | How |
|---|---|
| **Correctness** | LLM judge compares answer to an expected-points rubric |
| **Tool selection** | asserts the expected tool(s) were called (from the trace / response) |
| **Refusal correctness** | authz-denied actions must be declined, with no invented alternatives |
| **No hallucination** | judge flags invented order details / policies not from a tool |
| **Latency** | wall-clock per turn (budget per scenario) |

Each dimension yields a 0–1 score; a scenario passes if every dimension clears
its threshold. The suite prints a table and exits non-zero on any regression —
drop it into CI (module 1600 runs it as a release gate).

## Scenarios

`scenarios.yaml` is a list of `{persona, query, expect_tools, rubric,
must_refuse}` entries. They cover the retail flows the workshop builds:
order lookup, product RAG, returns (allowed for support, denied for sales),
and the analytical `run_python` path (900, sales-analyst only).

## Run

```bash
pip install -r requirements.txt

# Point at a deployed agent (port-forward or in-cluster) and the judge model.
export AGENT_URL=http://localhost:8080/chat
export JUDGE_MODEL_BASE_URL=http://localhost:4000/v1    # same gateway
export JUDGE_MODEL_ID=nova-pro                          # a stronger judge model

python runner.py scenarios.yaml
# -> prints a per-scenario score table; exit 0 = all pass, 1 = regression
```

As a Kubernetes Job (CI / scheduled):

```bash
kubectl apply -f k8s.yaml      # Job: runs runner.py against the in-cluster agent
kubectl logs job/agent-eval -f
```

## Files
- `runner.py` — replays scenarios, calls the judge, scores, prints table, sets exit code.
- `judge.py` — LLM-as-judge prompt + JSON-score parsing (OpenAI-compatible).
- `scenarios.yaml` — the persona scenario set.
- `test_runner.py` — unit tests for scoring/aggregation (mock judge).
- `requirements.txt`, `k8s.yaml`.

## Production deltas
- Use a **different / stronger** model as judge than the agent under test, and
  pin its version — judge drift is a real failure mode. Spot-check judge scores
  against a human-labeled golden set periodically.
- Keep scenarios in version control next to the prompts they guard; add a new
  scenario for every production incident (regression test culture).
