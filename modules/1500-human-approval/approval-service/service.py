"""Approval service — the authority that executes high-impact actions ONLY after
a human decision.

Key safety property: the agent can file a request and read its status, but it
cannot execute the action and has no self-approve path. Execution happens here,
inside approve(), after a human calls POST /requests/{id}/approve.

Requests persist in DynamoDB (APPROVALS_TABLE) with a TTL so they survive a
restart and don't accumulate forever. The actual "execution" is pluggable via
EXECUTORS keyed by action name — here we wire `initiate_return` to the orders
MCP tool as an example.
"""

import os
import time
import uuid

import boto3
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

REGION = os.environ.get("AWS_REGION")
APPROVALS_TABLE = os.environ.get("APPROVALS_TABLE", "agent_approvals")
TTL_SECONDS = int(os.environ.get("APPROVAL_TTL_SECONDS", str(7 * 24 * 3600)))

_table = boto3.resource("dynamodb", region_name=REGION).Table(APPROVALS_TABLE)
app = FastAPI(title="approval-service")


class ApprovalRequest(BaseModel):
    action: str                 # e.g. "initiate_return"
    args: dict                  # tool arguments to execute on approval
    persona: str | None = None
    summary: str | None = None  # human-readable description for the reviewer


# ---- pluggable executors: what actually runs when a request is approved ----

def _execute_initiate_return(args: dict) -> dict:
    """Example executor: perform the real return via the orders MCP/tool.

    Kept as a direct call for the workshop; in production this would call the
    MCP server (module 500) with the service's own scoped credentials — NOT the
    agent's — so the executing identity is the approval service, not the LLM.
    """
    # Placeholder for the real side effect; return a deterministic receipt.
    oid = str(args.get("order_id", "")).upper()
    return {
        "executed": "initiate_return",
        "order_id": oid,
        "return_id": f"RET-{oid.replace('ORD-', '')}",
        "reason": args.get("reason"),
    }


EXECUTORS = {
    "initiate_return": _execute_initiate_return,
}


def _put(item: dict) -> None:
    _table.put_item(Item=item)


def _get(request_id: str) -> dict | None:
    return _table.get_item(Key={"request_id": request_id}).get("Item")


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/requests")
def create_request(req: ApprovalRequest):
    """Agent files a request. Nothing executes here."""
    if req.action not in EXECUTORS:
        raise HTTPException(400, f"unknown gated action: {req.action}")
    request_id = f"ARQ-{uuid.uuid4().hex[:8].upper()}"
    now = int(time.time())
    item = {
        "request_id": request_id,
        "action": req.action,
        "args": req.args,
        "persona": req.persona or "unknown",
        "summary": req.summary or f"{req.action} {req.args}",
        "status": "PENDING",
        "created_at": now,
        "expires_at": now + TTL_SECONDS,
    }
    _put(item)
    return {"request_id": request_id, "status": "PENDING"}


@app.get("/pending")
def list_pending():
    """Reviewer lists pending requests (scan is fine at workshop scale)."""
    resp = _table.scan()
    pending = [i for i in resp.get("Items", []) if i.get("status") == "PENDING"]
    return {"pending": pending}


@app.get("/requests/{request_id}")
def get_request(request_id: str):
    item = _get(request_id)
    if not item:
        raise HTTPException(404, "not found")
    return item


@app.post("/requests/{request_id}/approve")
def approve(request_id: str):
    """Human approves -> the action executes HERE, then status flips."""
    item = _get(request_id)
    if not item:
        raise HTTPException(404, "not found")
    if item["status"] != "PENDING":
        raise HTTPException(409, f"already {item['status']}")

    executor = EXECUTORS.get(item["action"])
    if executor is None:  # defensive: action removed since creation
        raise HTTPException(400, f"no executor for {item['action']}")
    result = executor(item["args"])

    item["status"] = "APPROVED"
    item["result"] = result
    item["decided_at"] = int(time.time())
    _put(item)
    return {"request_id": request_id, "status": "APPROVED", "result": result}


@app.post("/requests/{request_id}/reject")
def reject(request_id: str):
    """Human rejects -> nothing executes."""
    item = _get(request_id)
    if not item:
        raise HTTPException(404, "not found")
    if item["status"] != "PENDING":
        raise HTTPException(409, f"already {item['status']}")
    item["status"] = "REJECTED"
    item["decided_at"] = int(time.time())
    _put(item)
    return {"request_id": request_id, "status": "REJECTED"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8080)
