"""Guardrails proxy — an OpenAI-compatible shim in front of the Envoy AI Gateway.

Agents keep calling the OpenAI `/v1/chat/completions` schema; we point their
MODEL_BASE_URL at this proxy. For each request we:

  1. run Bedrock ApplyGuardrail (source=INPUT) over the user turn AND the tool
     results in the message history — tool output is the real prompt-injection
     vector (search_products / order rows / MCP output are untrusted data),
  2. if the input is blocked, short-circuit with a safe refusal (never hit the
     model),
  3. otherwise forward unchanged to the real gateway,
  4. run ApplyGuardrail (source=OUTPUT) over the completion — masking PII, etc.,
  5. return the (possibly masked) completion.

Enforcement lives in a managed Bedrock Guardrail (created in Terraform); this
proxy only *applies* it on the OpenAI path, which Envoy AI Gateway doesn't
expose as an inline guardrailIdentifier. Blocked attempts are logged (and traced
to Langfuse when configured) so the eval harness (module 1300) can assert on
them.
"""

import os

import boto3
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

# Real OpenAI-compatible gateway (Envoy AI Gateway) we forward clean traffic to.
UPSTREAM = os.environ.get(
    "UPSTREAM_BASE_URL",
    "http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1",
)
GUARDRAIL_ID = os.environ["BEDROCK_GUARDRAIL_ID"]
GUARDRAIL_VERSION = os.environ.get("BEDROCK_GUARDRAIL_VERSION", "DRAFT")
REGION = os.environ.get("AWS_REGION")
REQUEST_TIMEOUT = 120

_bedrock = boto3.client("bedrock-runtime", region_name=REGION)
app = FastAPI(title="guardrails-proxy")

# Returned verbatim when the INPUT guardrail blocks — the model is never called.
_REFUSAL = (
    "I can't help with that request. If you have a question about your orders, "
    "products, or returns, I'm happy to help."
)


def _apply(text: str, source: str) -> tuple[bool, str]:
    """Run ApplyGuardrail. Returns (blocked, possibly_masked_text)."""
    if not text.strip():
        return False, text
    resp = _bedrock.apply_guardrail(
        guardrailIdentifier=GUARDRAIL_ID,
        guardrailVersion=GUARDRAIL_VERSION,
        source=source,  # "INPUT" or "OUTPUT"
        content=[{"text": {"text": text}}],
    )
    action = resp.get("action")  # NONE | GUARDRAIL_INTERVENED
    if action == "GUARDRAIL_INTERVENED":
        # outputs[] carries the masked/alternative text when available.
        outputs = resp.get("outputs") or []
        masked = outputs[0]["text"] if outputs else ""
        # A hard block (prompt attack, denied topic) yields no safe masked text.
        blocked = not masked
        return blocked, (masked or text)
    return False, text


def _screen_messages(messages: list[dict]) -> tuple[bool, list[dict]]:
    """Guardrail the user turn and any tool results in the history (INPUT)."""
    screened = []
    for m in messages:
        role = m.get("role")
        content = m.get("content")
        if role in ("user", "tool") and isinstance(content, str):
            blocked, masked = _apply(content, "INPUT")
            if blocked:
                return True, screened
            m = {**m, "content": masked}
        screened.append(m)
    return False, screened


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    messages = body.get("messages", [])

    blocked, screened = _screen_messages(messages)
    if blocked:
        print("[guardrails] INPUT blocked a request", flush=True)
        return JSONResponse(
            {
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": _REFUSAL},
                        "finish_reason": "content_filter",
                    }
                ],
                "guardrail": "input_blocked",
            }
        )
    body["messages"] = screened

    # Forward clean traffic to the real gateway.
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        upstream = await client.post(
            f"{UPSTREAM}/chat/completions",
            json=body,
            headers={"content-type": "application/json"},
        )
    data = upstream.json()

    # OUTPUT guardrail over the completion (mask PII, catch leaked content).
    try:
        content = data["choices"][0]["message"]["content"]
        if isinstance(content, str):
            _, masked = _apply(content, "OUTPUT")
            if masked != content:
                print("[guardrails] OUTPUT masked a completion", flush=True)
                data["choices"][0]["message"]["content"] = masked
    except (KeyError, IndexError, TypeError):
        pass  # non-standard body (streaming/error) — pass through untouched

    return JSONResponse(data, status_code=upstream.status_code)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8080)
