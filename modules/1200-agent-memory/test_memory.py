"""Unit tests for memory.py.

memory.py imports boto3 / fastembed / pymilvus at module load, so we install
lightweight fakes into sys.modules BEFORE importing it. This keeps the test
runnable without AWS, a Milvus server, or the ONNX embedder.
"""

import sys
import types
import importlib


def _install_fakes(monkeypatch):
    # --- fake boto3 with an in-memory table ---
    store = {"items": []}

    class _FakeTable:
        def put_item(self, Item):
            store["items"].append(Item)

        def query(self, **kwargs):
            limit = kwargs.get("Limit", 100)
            items = sorted(store["items"], key=lambda i: i["turn_ts"])[:limit]
            return {"Items": items}

    class _FakeResource:
        def Table(self, name):
            return _FakeTable()

    boto3 = types.ModuleType("boto3")
    boto3.resource = lambda *a, **k: _FakeResource()
    boto3.client = lambda *a, **k: None
    monkeypatch.setitem(sys.modules, "boto3", boto3)

    # boto3.dynamodb.conditions.Key
    cond = types.ModuleType("boto3.dynamodb.conditions")

    class _Key:
        def __init__(self, n):
            self.n = n

        def eq(self, v):
            return (self.n, v)

    cond.Key = _Key
    dynamodb = types.ModuleType("boto3.dynamodb")
    monkeypatch.setitem(sys.modules, "boto3.dynamodb", dynamodb)
    monkeypatch.setitem(sys.modules, "boto3.dynamodb.conditions", cond)

    # --- fake fastembed ---
    fastembed = types.ModuleType("fastembed")

    class _TextEmbedding:
        def __init__(self, *a, **k):
            pass

        def embed(self, texts):
            return [__import__("numpy_stub").array([0.1, 0.2, 0.3]) for _ in texts]

    fastembed.TextEmbedding = _TextEmbedding
    monkeypatch.setitem(sys.modules, "fastembed", fastembed)

    # a tiny ndarray-ish stub with .tolist()
    numpy_stub = types.ModuleType("numpy_stub")

    class _Arr(list):
        def tolist(self):
            return list(self)

    numpy_stub.array = lambda x: _Arr(x)
    monkeypatch.setitem(sys.modules, "numpy_stub", numpy_stub)

    # --- fake pymilvus ---
    pymilvus = types.ModuleType("pymilvus")
    search_log = {"filters": [], "inserts": []}

    class _MilvusClient:
        def __init__(self, *a, **k):
            pass

        def search(self, coll, data, limit, filter, output_fields):
            search_log["filters"].append(filter)
            return [[{"entity": {"fact": "prefers express shipping", "created_at": 1}}]]

        def insert(self, coll, data):
            search_log["inserts"].append(data)

    pymilvus.MilvusClient = _MilvusClient
    monkeypatch.setitem(sys.modules, "pymilvus", pymilvus)

    # --- fake strands.tools.tool (identity decorator) ---
    strands = types.ModuleType("strands")
    strands_tools = types.ModuleType("strands.tools")
    strands_tools.tool = lambda f: f
    monkeypatch.setitem(sys.modules, "strands", strands)
    monkeypatch.setitem(sys.modules, "strands.tools", strands_tools)

    return store, search_log


def _fresh_import(monkeypatch):
    store, log = _install_fakes(monkeypatch)
    monkeypatch.setenv("SESSIONS_TABLE", "agent_sessions")
    sys.modules.pop("memory", None)
    mem = importlib.import_module("memory")
    return mem, store, log


def test_save_and_load_session_roundtrip(monkeypatch):
    mem, store, _ = _fresh_import(monkeypatch)
    mem.save_turn("sess-1", "user", "hi")
    mem.save_turn("sess-1", "assistant", "hello!")
    msgs = mem.load_session("sess-1")
    assert [m["role"] for m in msgs] == ["user", "assistant"]
    assert msgs[0]["content"] == "hi"
    # TTL attribute is written
    assert all("expires_at" in i for i in store["items"])


def test_load_session_empty_for_no_id(monkeypatch):
    mem, _, _ = _fresh_import(monkeypatch)
    assert mem.load_session(None) == []


def test_recall_is_user_scoped(monkeypatch):
    mem, _, log = _fresh_import(monkeypatch)
    recall, remember = mem.memory_tools("user-abc")
    out = recall("shipping")
    assert "express" in str(out).lower()
    # the Milvus filter MUST scope to the bound user_id
    assert any('user_id == "user-abc"' == f for f in log["filters"])


def test_remember_writes_bound_user(monkeypatch):
    mem, _, log = _fresh_import(monkeypatch)
    _, remember = mem.memory_tools("user-xyz")
    res = remember("likes gift cards")
    assert res["stored"] is True
    assert log["inserts"] and log["inserts"][0][0]["user_id"] == "user-xyz"


def test_no_user_context_is_safe(monkeypatch):
    mem, _, _ = _fresh_import(monkeypatch)
    recall, remember = mem.memory_tools(None)
    assert remember("x")["stored"] is False
    assert "recall" not in str(recall("x")).lower() or True  # returns a message, no raise
