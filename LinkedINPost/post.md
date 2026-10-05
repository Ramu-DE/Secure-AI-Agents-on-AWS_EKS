🎉 Thrilled to have attended an AWS in-person event — bringing my strong containers skills to the table! 💪🐳

🚀 I just worked through an incredible hands-on workshop: building production-grade, secure AI agents on Amazon EKS — from a single chatbot to a fully autonomous coding agent. Here's the journey. 🧵

Most "AI agent" demos stop at a prompt and an API call. This one goes further: identity propagation, per-persona authorization, hardware-level sandboxing, and real observability. Each module builds on the last.

🧩 Module by module:

200 — Strands Agents: A customer-service agent built with the Strands SDK, talking to an OpenAI-compatible gateway in front of Amazon Bedrock. The foundation.

300 — Observability (Langfuse): Every interaction becomes a trace, tagged by session and persona — so you can SEE what your agent does and debug it.

500 — Tools via MCP: The agent gains real tools (order lookup, product search, inventory, returns) through the Model Context Protocol — granted per user.

600 — Multi-Agent (A2A): An orchestrator routes requests to specialist agents over Agent-to-Agent messaging. Clean separation of concerns.

700 — Persona AuthZ at the gateway: Cognito identity flows end to end. agentgateway validates the JWT and authorizes each tool call by the user's group. Unauthorized tools are HIDDEN from the agent — not just blocked.

800 — Identity propagation: The user's identity rides through the whole chain (UI → orchestrator → specialist → MCP) and is enforced on every hop.

900 — Sandboxed code execution: For analytics, the agent WRITES Python and runs it in a per-execution Firecracker microVM — air-gapped, no network, no credentials.

1000 — Autonomous Coding Agent (capstone): A labeled Git issue triggers Claude Code inside a kata-Firecracker microVM. It clones, edits, tests, commits, pushes a branch, and opens a PR — with NO human ever handling a git credential. 🤯

⚙️ Then the production-hardening track — the unglamorous 90% that separates a demo from a real system:

1100 — Guardrails: Bedrock Guardrails on the model path, screening not just user input but TOOL RESULTS (the real prompt-injection vector).

1200 — Agent memory: short-term session state (DynamoDB) + long-term semantic memory (Milvus), scoped per user — the agent remembers across sessions, safely.

1300 — Evaluation harness: an LLM-as-judge regression suite replaying persona scenarios, including authz-negative cases. Quality becomes a CI gate, not a vibe.

1400 — Resilience & cost: per-persona rate limits, TOKEN budgets (cost is tokens, not requests), retries, circuit breaking, and model fallback — all at the gateway.

1500 — Human-in-the-loop: high-impact actions pause for a human. The agent can only PROPOSE; a separate service executes after approval. Even a jailbroken agent can't self-approve.

1600 — GitOps & progressive delivery: Argo CD + Argo Rollouts. New versions ship as canaries gated by the 1300 evals — a bad prompt is caught on 10% of traffic and auto-rolled-back.

1700 — Multi-region DR: DynamoDB global tables, Route 53 failover, and cross-region Bedrock failover — the platform survives a regional outage.

🔐 What makes this different: security isn't an afterthought. Hardware-isolated microVMs, deny-by-default authz, short-lived per-run tokens, air-gapped execution, and full tracing — the patterns you actually need in production.

Key takeaways:
✅ Identity must propagate across every agent hop — not just at the front door
✅ Untrusted, model-generated code belongs in a sandbox (Firecracker > containers for isolation)
✅ Per-persona, deny-by-default authz keeps agents honest
✅ Observability turns a black box into something you can trust

Composing Strands, MCP, A2A, agentgateway, Cognito, kata + Firecracker, Langfuse, and Bedrock into one coherent, secure platform. 👏

If you're building agents and only thinking about prompts, you're missing the hard 90%: identity, authorization, isolation, and observability. 💡

#AI #AgenticAI #AWS #AmazonBedrock #Kubernetes #EKS #Security #MCP #Firecracker #LLM #PlatformEngineering
