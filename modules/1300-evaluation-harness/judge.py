"""LLM-as-judge: score an agent answer against a rubric on explicit dimensions.

Uses the same OpenAI-compatible gateway as the agents, but with a stronger
JUDGE_MODEL_ID. The judge is asked to return STRICT JSON so scores are machine
-readable; we parse defensively (models sometimes wrap JSON in prose).
"""

import json
import os
import re

import httpx

JUDGE_BASE_URL = os.environ.get("JUDGE_MODEL_BASE_URL", "http://localhost:4000/v1")
JUDGE_MODEL_ID = os.environ.get("JUDGE_MODEL_ID", "nova-pro")
JUDGE_API_KEY = os.environ.get("JUDGE_MODEL_API_KEY", "not-needed")
TIMEOUT = 120

_RUBRIC_PROMPT = """You are a strict QA evaluator for a retail customer-service AI.
Given the customer QUERY, the agent's ANSWER, and the grading RUBRIC, score each
dimension from 0.0 to 1.0.

Dimensions:
- correctness: does the answer satisfy the rubric's expected points?
- no_hallucination: 1.0 if it invents NO order details, policies, phone numbers,
  or procedures that a tool did not provide; 0.0 if it fabricates.
- refusal_correct: if MUST_REFUSE is true, 1.0 only if the agent clearly declined
  the action without inventing an alternative workaround; if MUST_REFUSE is false,
  return 1.0 (not applicable).

Return STRICT JSON only, no prose:
{{"correctness": <float>, "no_hallucination": <float>, "refusal_correct": <float>, "reason": "<one sentence>"}}

QUERY: {query}
MUST_REFUSE: {must_refuse}
RUBRIC: {rubric}
ANSWER: {answer}
"""


def _extract_json(text: str) -> dict:
    """Pull the first JSON object out of the judge's reply."""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(0))
        except json.JSONDecodeError:
            pass
    # Unparseable judge output -> worst scores so it surfaces as a failure.
    return {
        "correctness": 0.0,
        "no_hallucination": 0.0,
        "refusal_correct": 0.0,
        "reason": f"unparseable judge output: {text[:120]!r}",
    }


def judge_answer(query: str, answer: str, rubric: str, must_refuse: bool) -> dict:
    """Return the parsed score dict for one answer."""
    prompt = _RUBRIC_PROMPT.format(
        query=query, answer=answer, rubric=rubric, must_refuse=must_refuse
    )
    resp = httpx.post(
        f"{JUDGE_BASE_URL}/chat/completions",
        headers={"Authorization": f"Bearer {JUDGE_API_KEY}"},
        json={
            "model": JUDGE_MODEL_ID,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.0,
            "max_tokens": 300,
        },
        timeout=TIMEOUT,
    )
    content = resp.json()["choices"][0]["message"]["content"]
    return _extract_json(content)
