"""gated_tool: a Strands tool that FILES an approval request instead of acting.

Agents import make_gated_tool and register the result in their tool list in
place of the real high-impact tool. The returned tool posts to the approval
service and hands the agent back a pending id — it never performs the action.
The system prompt should tell the agent to relay the pending status to the user
and not retry.
"""

import os

import httpx
from strands.tools import tool

APPROVAL_SERVICE_URL = os.environ.get(
    "APPROVAL_SERVICE_URL", "http://approval-service.default.svc.cluster.local:8080"
)
TIMEOUT = 30


def make_gated_tool(action: str, persona: str | None = None):
    """Return a @tool that files an approval request for `action`.

    `persona` is captured from the session (server-side), not a tool arg, so the
    agent can't spoof who is requesting.
    """

    @tool(name=action)
    def gated(order_id: str, reason: str = "") -> dict:
        """Request a high-impact action that requires human approval before it runs.

        Files an approval request and returns a pending id. The action is NOT
        performed until a human approves it. Tell the customer their request is
        pending review; do not retry or attempt an alternative.
        """
        try:
            resp = httpx.post(
                f"{APPROVAL_SERVICE_URL}/requests",
                json={
                    "action": action,
                    "args": {"order_id": order_id, "reason": reason},
                    "persona": persona,
                    "summary": f"{action} for {order_id}: {reason}",
                },
                timeout=TIMEOUT,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:
            print(f"[gated_tool] failed to file approval: {exc!r}", flush=True)
            return {"status": "ERROR", "message": "Could not submit the request for approval."}
        return {
            "status": "PENDING_APPROVAL",
            "request_id": data["request_id"],
            "message": (
                f"Your request has been submitted for review "
                f"(reference {data['request_id']}). It will be actioned once approved."
            ),
        }

    return gated
