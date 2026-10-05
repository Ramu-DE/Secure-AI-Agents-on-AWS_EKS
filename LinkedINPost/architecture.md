# Workshop Architecture & Flow

Secure AI agents on Amazon EKS — from a single agent to an autonomous coding agent.
Each module builds on the previous one; the diagrams below layer up the same way.

---

## 1. End-to-end architecture

```mermaid
flowchart TB
    subgraph User["👤 User"]
        UI["Chat UI (Chainlit)<br/>persona login via Cognito"]
    end

    subgraph Identity["🔐 Identity"]
        COG["Amazon Cognito<br/>(JWT · cognito:groups)"]
    end

    subgraph Gateway["🚪 agentgateway"]
        GW["JWT validation (authn)<br/>per-tool / per-hop authz<br/>deny-by-default"]
    end

    subgraph Agents["🤖 Agents on EKS"]
        ORCH["Orchestrator<br/>(routing agent · 600)"]
        ORDER["Order Agent<br/>(A2A specialist)"]
        PROD["Product Agent<br/>(A2A specialist)"]
        CUST["Customer Agent<br/>(single-agent · 200/300/500)"]
    end

    subgraph Tools["🧰 Tools & Data"]
        MCP["MCP Server<br/>lookup_order · search_products<br/>check_inventory · initiate_return"]
        DDB[("DynamoDB<br/>orders / products")]
    end

    subgraph Sandbox["🧪 Firecracker microVMs (kata-fc)"]
        PYVM["Python microVM (900)<br/>air-gapped · run_python"]
        CODEVM["Coding microVM (1000)<br/>Claude Code · clone→edit→test→PR"]
    end

    subgraph Model["🧠 Model layer"]
        AIGW["Envoy AI Gateway<br/>(OpenAI / Anthropic compatible)"]
        BR["Amazon Bedrock<br/>(Nova / Claude)"]
    end

    subgraph Obs["📊 Observability"]
        LF["Langfuse<br/>traces · sessions · personas"]
    end

    subgraph Git["📦 Gitea (in-cluster)"]
        GITEA["Repo + issues + webhook"]
        DISP["Coding Agent Dispatcher<br/>mint/revoke per-run token"]
    end

    UI -->|login| COG
    UI -->|Bearer token| GW
    GW --> ORCH
    GW --> CUST

    ORCH -->|A2A + token| ORDER
    ORCH -->|A2A + token| PROD
    ORDER -->|MCP + token| GW
    CUST -->|MCP + token| GW
    GW --> MCP
    MCP --> DDB

    CUST -->|run_python| GW
    GW --> PYVM
    PYVM -->|scoped slice| DDB

    GITEA -->|issue labeled 'agent'| DISP
    DISP -->|SandboxClaim| CODEVM
    CODEVM -->|push branch + PR| GITEA

    ORCH & CUST & ORDER & PROD & CODEVM --> AIGW
    AIGW --> BR

    ORCH & CUST & ORDER & PROD -.trace.-> LF
    CODEVM -.trace.-> LF

    classDef sec fill:#ffe8e8,stroke:#c0392b,color:#000;
    classDef infra fill:#e8f0ff,stroke:#2c6fbb,color:#000;
    class COG,GW sec;
    class AIGW,BR,LF infra;
```

---

## 2. Request flow — multi-agent query (modules 200→800)

```mermaid
sequenceDiagram
    autonumber
    actor U as User (persona)
    participant UI as Chat UI
    participant GW as agentgateway
    participant O as Orchestrator
    participant OA as Order Agent
    participant M as MCP Server
    participant B as Bedrock (via AI GW)
    participant L as Langfuse

    U->>UI: "Where is my order ORD-1001?"
    UI->>GW: POST /chat (Bearer JWT)
    GW->>GW: validate JWT (authn)
    GW->>O: forward request + token
    O->>B: decide routing
    O->>GW: A2A call → Order Agent (+token)
    GW->>GW: authz: has(jwt.sub)? ✅
    GW->>OA: forward A2A (+token)
    OA->>GW: MCP call_tool lookup_order (+token)
    GW->>GW: authz: tool allowed for persona? ✅
    GW->>M: call_tool
    M-->>OA: order status
    OA-->>O: reply
    O-->>UI: final answer
    UI-->>U: "Your order shipped…"
    Note over O,L: Spans traced per session & persona
    O-->>L: trace
```

---

## 3. Autonomous coding agent — capstone (module 1000)

```mermaid
sequenceDiagram
    autonumber
    actor H as Human
    participant G as Gitea
    participant D as Dispatcher
    participant S as Coding microVM (kata-fc)
    participant A as Envoy AI GW → Bedrock (Claude)

    H->>G: File issue + label `agent`
    G->>D: webhook (issues event, HMAC-verified)
    D->>D: mint per-run Gitea token
    D->>S: create sandbox (SandboxClaim)
    D->>S: write git-credentials + task.md (out-of-band)
    S->>G: clone repo (in-cluster, egress-locked)
    S->>A: model calls (claude -p)
    A-->>S: code suggestions
    S->>S: edit → test → commit
    S->>G: push branch + open PR
    D->>G: verify PR → comment link on issue
    D->>S: terminate sandbox
    D->>D: revoke per-run token
    Note over S: No human ever handles a git credential 🔐
```

---

## 4. Advanced / production-hardening modules (1100–1700)

These layer on top of the core stack — safety, memory, evaluation, cost
controls, controlled autonomy, delivery, and resilience.

```mermaid
flowchart TB
    subgraph Core["Core platform (200–1000)"]
        AGENTS["Agents + agentgateway + MCP + sandboxes + Bedrock"]
    end

    subgraph Safety["🛡️ Safety & quality"]
        G1100["1100 Guardrails<br/>prompt-injection / PII filter"]
        G1300["1300 Eval harness<br/>LLM-as-judge regression gate"]
        G1500["1500 Human-in-the-loop<br/>approval for high-impact actions"]
    end

    subgraph State["🧠 State & cost"]
        G1200["1200 Agent memory<br/>DynamoDB + Milvus"]
        G1400["1400 Resilience & cost<br/>rate limits · token budgets · fallback"]
    end

    subgraph Ops["🚀 Delivery & resilience"]
        G1600["1600 GitOps<br/>Argo CD + canary rollouts"]
        G1700["1700 Multi-region DR<br/>global tables · Bedrock failover"]
    end

    G1100 --> AGENTS
    G1200 --> AGENTS
    G1400 --> AGENTS
    G1500 --> AGENTS
    AGENTS --> G1300
    G1300 -->|release gate| G1600
    G1600 --> G1700

    classDef adv fill:#fff4e0,stroke:#d08a1d,color:#000;
    class G1100,G1200,G1300,G1400,G1500,G1600,G1700 adv;
```

| Module | Adds | Builds on |
|---|---|---|
| **1100** Guardrails | Bedrock Guardrails on the model path (screens user turns *and* tool results) | AI Gateway seam; untrusted-tool-output threat model |
| **1200** Agent memory | Short-term (DynamoDB) + long-term semantic (Milvus) memory per user/session | 300 session ids, 500 Milvus |
| **1300** Eval harness | LLM-as-judge regression suite over persona scenarios (incl. authz-negative) | 300 traces, 500/700 authz |
| **1400** Resilience & cost | Per-persona rate limits, token budgets, retries, circuit breaking, model fallback | Envoy AI Gateway / agentgateway |
| **1500** Human-in-the-loop | Approval service: agent proposes, human approves, service executes | 500/700 mutating tools, 1000 autonomy |
| **1600** GitOps | Argo CD App-of-Apps + Argo Rollouts canary gated by the 1300 evals | every module's k8s.yaml, 1300 |
| **1700** Multi-region DR | DynamoDB global tables, Route 53 failover, cross-region Bedrock | 1400 fallback, all stateful deps |

### Security themes baked into every layer
- **Identity propagates** across every hop (UI → orchestrator → specialist → MCP / A2A).
- **Deny-by-default authz** at agentgateway; unauthorized tools are *hidden*, not just blocked.
- **Hardware isolation**: untrusted, model-generated code runs in per-execution Firecracker microVMs.
- **Air-gapped sandboxes**: no network, no AWS creds; data injected out-of-band.
- **Short-lived per-run tokens** for the coding agent, auto-revoked.
- **Full observability** via Langfuse traces, grouped by session and persona.
