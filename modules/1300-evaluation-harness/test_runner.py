"""Unit tests for the eval runner's scoring/aggregation (judge mocked)."""

import sys
import types


def _install_fakes(monkeypatch, judge_scores):
    # fake httpx (runner imports it; not used in these pure-function tests)
    monkeypatch.setitem(sys.modules, "httpx", types.ModuleType("httpx"))
    # fake yaml (imported at top of runner)
    monkeypatch.setitem(sys.modules, "yaml", types.ModuleType("yaml"))
    # fake judge module so score_scenario doesn't hit a model
    judge_mod = types.ModuleType("judge")
    judge_mod.judge_answer = lambda **kw: dict(judge_scores)
    monkeypatch.setitem(sys.modules, "judge", judge_mod)
    sys.modules.pop("runner", None)
    import importlib

    return importlib.import_module("runner")


_PERFECT = {"correctness": 1.0, "no_hallucination": 1.0, "refusal_correct": 1.0, "reason": "ok"}


def test_passing_scenario(monkeypatch):
    runner = _install_fakes(monkeypatch, _PERFECT)
    sc = {"name": "s", "query": "q", "expect_tools": ["lookup_order"], "rubric": "r"}
    r = runner.score_scenario(sc, "answer", ["lookup_order"], latency=1.0)
    assert r["passed"] is True


def test_missing_expected_tool_fails(monkeypatch):
    runner = _install_fakes(monkeypatch, _PERFECT)
    sc = {"name": "s", "query": "q", "expect_tools": ["lookup_order"], "rubric": "r"}
    r = runner.score_scenario(sc, "answer", [], latency=1.0)  # tool NOT called
    assert r["tools_ok"] is False
    assert r["passed"] is False


def test_hallucination_fails(monkeypatch):
    bad = {**_PERFECT, "no_hallucination": 0.0}
    runner = _install_fakes(monkeypatch, bad)
    sc = {"name": "s", "query": "q", "rubric": "r"}
    r = runner.score_scenario(sc, "made up stuff", [], latency=1.0)
    assert r["passed"] is False


def test_must_refuse_but_called_denied_tool_fails(monkeypatch):
    runner = _install_fakes(monkeypatch, _PERFECT)
    sc = {
        "name": "deny", "query": "q", "rubric": "r",
        "must_refuse": True, "denied_tool": "initiate_return",
    }
    r = runner.score_scenario(sc, "I did the return", ["initiate_return"], latency=1.0)
    assert r["tools_ok"] is False
    assert r["passed"] is False


def test_latency_budget_fails(monkeypatch):
    runner = _install_fakes(monkeypatch, _PERFECT)
    sc = {"name": "slow", "query": "q", "rubric": "r"}
    r = runner.score_scenario(sc, "answer", [], latency=999.0)
    assert r["latency_ok"] is False
    assert r["passed"] is False


def test_summarize_counts(monkeypatch):
    runner = _install_fakes(monkeypatch, _PERFECT)
    results = [{"passed": True}, {"passed": False}, {"passed": True}]
    assert runner.summarize(results) == (2, 3)
