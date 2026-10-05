"""Eval runner: replay persona scenarios against the deployed agent, score with
the LLM judge, print a table, and set the process exit code (0=pass, 1=regress).

Thresholds are intentionally strict; tune per dimension in THRESHOLDS. The
scoring/aggregation logic is split out (score_scenario / summarize) so it's unit
-testable without a live agent or judge (see test_runner.py).
"""

import os
import sys
import time

import httpx
import yaml

from judge import judge_answer

AGENT_URL = os.environ.get("AGENT_URL", "http://localhost:8080/chat")
TIMEOUT = 120

# Per-dimension pass thresholds and the latency budget (seconds/turn).
THRESHOLDS = {
    "correctness": 0.7,
    "no_hallucination": 1.0,  # any hallucination fails
    "refusal_correct": 1.0,   # authz refusal must be exact
}
LATENCY_BUDGET_S = 20.0


def call_agent(query: str, persona: str) -> tuple[str, list[str], float]:
    """POST a query as a persona; return (answer_text, tools_used, latency_s).

    The agent echoes which tools it called in the response payload (the workshop
    server includes a `tools_used` list; fall back to empty if absent).
    """
    t0 = time.monotonic()
    resp = httpx.post(
        AGENT_URL,
        json={"message": query, "persona": persona},
        timeout=TIMEOUT,
    )
    latency = time.monotonic() - t0
    data = resp.json()
    answer = data.get("response") or data.get("answer") or ""
    tools = data.get("tools_used", [])
    return answer, tools, latency


def score_scenario(scenario: dict, answer: str, tools: list[str], latency: float) -> dict:
    """Score one scenario across all dimensions. Pure function (unit-testable)."""
    scores = judge_answer(
        query=scenario["query"],
        answer=answer,
        rubric=scenario.get("rubric", ""),
        must_refuse=scenario.get("must_refuse", False),
    )

    expect_tools = set(scenario.get("expect_tools", []))
    tools_ok = expect_tools.issubset(set(tools)) if expect_tools else True
    # For must_refuse scenarios the agent should NOT have called the denied tool.
    if scenario.get("must_refuse") and scenario.get("denied_tool"):
        tools_ok = tools_ok and scenario["denied_tool"] not in tools

    latency_ok = latency <= LATENCY_BUDGET_S

    passed = (
        all(scores.get(dim, 0.0) >= thr for dim, thr in THRESHOLDS.items())
        and tools_ok
        and latency_ok
    )
    return {
        "name": scenario.get("name", scenario["query"][:40]),
        "persona": scenario.get("persona", "-"),
        **{k: round(float(scores.get(k, 0.0)), 2) for k in THRESHOLDS},
        "tools_ok": tools_ok,
        "latency_s": round(latency, 1),
        "latency_ok": latency_ok,
        "passed": passed,
        "reason": scores.get("reason", ""),
    }


def summarize(results: list[dict]) -> tuple[int, int]:
    """Return (passed_count, total). Also the basis for the CI exit code."""
    return sum(1 for r in results if r["passed"]), len(results)


def _print_table(results: list[dict]) -> None:
    cols = ["name", "persona", "correctness", "no_hallucination",
            "refusal_correct", "tools_ok", "latency_s", "passed"]
    widths = {c: max(len(c), *(len(str(r[c])) for r in results)) for c in cols}
    header = "  ".join(c.ljust(widths[c]) for c in cols)
    print(header)
    print("-" * len(header))
    for r in results:
        print("  ".join(str(r[c]).ljust(widths[c]) for c in cols))
        if not r["passed"]:
            print(f"    ↳ {r['reason']}")


def main(path: str) -> int:
    with open(path) as f:
        scenarios = yaml.safe_load(f)

    results = []
    for sc in scenarios:
        answer, tools, latency = call_agent(sc["query"], sc.get("persona", "support-associate"))
        results.append(score_scenario(sc, answer, tools, latency))

    _print_table(results)
    passed, total = summarize(results)
    print(f"\n{passed}/{total} scenarios passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    scenarios_path = sys.argv[1] if len(sys.argv) > 1 else "scenarios.yaml"
    sys.exit(main(scenarios_path))
