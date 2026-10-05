"""Agent memory: short-term session transcript (DynamoDB) + long-term semantic
memory (Milvus), plus the two Strands tools the agent uses to recall/remember.

Design mirrors the rest of the workshop:
  * short-term  -> DynamoDB table SESSIONS_TABLE, pk=session_id, TTL on expires_at
  * long-term   -> Milvus collection `agent_memory`, filtered by user_id,
                   embedded with the SAME fastembed model as the 500 product RAG
                   (vectors interchangeable, no extra infra).

Integration (server.py / build_session_agent):

    from memory import load_session, save_turn, memory_tools
    messages = load_session(session_id)                 # seed prior turns
    agent = Agent(..., messages=messages,
                  tools=[*your_tools, *memory_tools(user_id)])
    ...
    save_turn(session_id, "user", user_text)
    save_turn(session_id, "assistant", answer_text)
"""

import os
import time
import uuid

import boto3
from boto3.dynamodb.conditions import Key
from fastembed import TextEmbedding
from pymilvus import MilvusClient
from strands.tools import tool

REGION = os.environ.get("AWS_REGION")
SESSIONS_TABLE = os.environ.get("SESSIONS_TABLE", "agent_sessions")
MILVUS_URI = os.environ.get("MILVUS_URI", "http://localhost:19530")
MEMORY_COLLECTION = "agent_memory"
SESSION_TTL_SECONDS = int(os.environ.get("SESSION_TTL_SECONDS", str(24 * 3600)))
SHORT_TERM_WINDOW = int(os.environ.get("SHORT_TERM_WINDOW", "20"))  # last N turns
MODEL_CACHE = "/app/.fastembed_cache"  # matches rag_tools.py pre-pop path

_table = boto3.resource("dynamodb", region_name=REGION).Table(SESSIONS_TABLE)
_embedder = TextEmbedding(
    model_name="sentence-transformers/all-MiniLM-L6-v2", cache_dir=MODEL_CACHE
)
_milvus = MilvusClient(uri=MILVUS_URI)


# ---------------------------------------------------------------- short-term

def load_session(session_id: str | None) -> list[dict]:
    """Return the stored transcript window as Strands/OpenAI messages."""
    if not session_id:
        return []
    try:
        resp = _table.query(
            KeyConditionExpression=Key("session_id").eq(session_id),
            ScanIndexForward=True,  # oldest first
            Limit=SHORT_TERM_WINDOW,
        )
    except Exception as exc:  # table missing / throttled — degrade, don't crash
        print(f"[memory] load_session failed: {exc!r}", flush=True)
        return []
    return [{"role": i["role"], "content": i["content"]} for i in resp.get("Items", [])]


def save_turn(session_id: str | None, role: str, content: str) -> None:
    """Append one turn to the session with a 24h TTL."""
    if not session_id or not content:
        return
    now = time.time()
    try:
        _table.put_item(
            Item={
                "session_id": session_id,
                # sort key: monotonic so ScanIndexForward orders turns correctly
                "turn_ts": f"{now:.6f}-{uuid.uuid4().hex[:8]}",
                "role": role,
                "content": content,
                "expires_at": int(now + SESSION_TTL_SECONDS),  # DynamoDB TTL attr
            }
        )
    except Exception as exc:
        print(f"[memory] save_turn failed: {exc!r}", flush=True)


# ----------------------------------------------------------------- long-term

def _embed(text: str) -> list[float]:
    return next(iter(_embedder.embed([text]))).tolist()


def memory_tools(user_id: str | None):
    """Build the recall/remember tools BOUND to this user (server-side scoping).

    user_id is captured in the closure, never taken as a tool argument — so the
    model cannot read or write another user's memory by passing a different id.
    """

    @tool
    def recall_memory(query: str, limit: int = 3) -> list:
        """Recall facts you previously stored about THIS user (preferences, past context)."""
        if not user_id:
            return [{"message": "No user context; nothing to recall."}]
        try:
            results = _milvus.search(
                MEMORY_COLLECTION,
                data=[_embed(query)],
                limit=limit,
                filter=f'user_id == "{user_id}"',  # server-side scope
                output_fields=["fact", "created_at"],
            )
        except Exception as exc:
            print(f"[memory] recall failed: {exc!r}", flush=True)
            return [{"message": "Memory is temporarily unavailable."}]
        facts = [h["entity"]["fact"] for h in results[0]] if results else []
        return facts or [{"message": "No relevant memories found."}]

    @tool
    def remember(fact: str) -> dict:
        """Store a durable fact about THIS user (e.g. a stated preference)."""
        if not user_id:
            return {"stored": False, "reason": "no user context"}
        try:
            _milvus.insert(
                MEMORY_COLLECTION,
                data=[
                    {
                        "id": uuid.uuid4().int >> 64,  # 64-bit pk
                        "user_id": user_id,
                        "fact": fact,
                        "created_at": int(time.time()),
                        "vector": _embed(fact),
                    }
                ],
            )
        except Exception as exc:
            print(f"[memory] remember failed: {exc!r}", flush=True)
            return {"stored": False, "reason": "memory unavailable"}
        return {"stored": True, "fact": fact}

    return [recall_memory, remember]
