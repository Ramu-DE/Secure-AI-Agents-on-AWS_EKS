"""Unit tests for the approval state machine (DynamoDB mocked in-memory).

Verifies the core safety property: nothing executes until approve(), reject()
executes nothing, and a resolved request can't be re-decided.
"""

import sys
import types
import importlib

import pytest


def _install_fakes(monkeypatch):
    store = {}

    class _FakeTable:
        def put_item(self, Item):
            store[Item["request_id"]] = Item

        def get_item(self, Key):
            item = store.get(Key["request_id"])
            return {"Item": item} if item else {}

        def scan(self):
            return {"Items": list(store.values())}

    class _FakeResource:
        def Table(self, name):
            return _FakeTable()

    boto3 = types.ModuleType("boto3")
    boto3.resource = lambda *a, **k: _FakeResource()
    monkeypatch.setitem(sys.modules, "boto3", boto3)
    sys.modules.pop("service", None)
    return importlib.import_module("service"), store


def test_create_is_pending_and_does_not_execute(monkeypatch):
    svc, store = _install_fakes(monkeypatch)
    req = svc.ApprovalRequest(action="initiate_return", args={"order_id": "ORD-1", "reason": "x"})
    out = svc.create_request(req)
    assert out["status"] == "PENDING"
    stored = store[out["request_id"]]
    assert stored["status"] == "PENDING"
    assert "result" not in stored  # nothing executed


def test_unknown_action_rejected(monkeypatch):
    svc, _ = _install_fakes(monkeypatch)
    with pytest.raises(svc.HTTPException):
        svc.create_request(svc.ApprovalRequest(action="delete_everything", args={}))


def test_approve_executes_once(monkeypatch):
    svc, _ = _install_fakes(monkeypatch)
    rid = svc.create_request(
        svc.ApprovalRequest(action="initiate_return", args={"order_id": "ORD-9", "reason": "damaged"})
    )["request_id"]
    res = svc.approve(rid)
    assert res["status"] == "APPROVED"
    assert res["result"]["return_id"] == "RET-9"
    # re-approving a resolved request is a conflict
    with pytest.raises(svc.HTTPException):
        svc.approve(rid)


def test_reject_executes_nothing(monkeypatch):
    svc, store = _install_fakes(monkeypatch)
    rid = svc.create_request(
        svc.ApprovalRequest(action="initiate_return", args={"order_id": "ORD-7", "reason": "x"})
    )["request_id"]
    res = svc.reject(rid)
    assert res["status"] == "REJECTED"
    assert "result" not in store[rid]


def test_pending_list(monkeypatch):
    svc, _ = _install_fakes(monkeypatch)
    svc.create_request(svc.ApprovalRequest(action="initiate_return", args={"order_id": "A"}))
    r2 = svc.create_request(svc.ApprovalRequest(action="initiate_return", args={"order_id": "B"}))["request_id"]
    svc.approve(r2)
    pending = svc.list_pending()["pending"]
    assert len(pending) == 1 and pending[0]["args"]["order_id"] == "A"
