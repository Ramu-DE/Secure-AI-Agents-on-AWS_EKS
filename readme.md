# Secure AI Agents on Amazon EKS

Build production-grade, **secure** AI agents on Amazon EKS — progressively, from a
single chatbot to a fully autonomous coding agent, then hardened for production.

Most "AI agent" demos stop at a prompt and an API call. This workshop goes
further: **identity propagation, per-persona authorization, hardware-level
sandboxing, observability, evaluation, and resilience** — the patterns you
actually need to run agents in production.

Agents are built with the **Strands SDK**, served on **EKS**, fronted by
**agentgateway** (MCP/A2A authz) and the **Envoy AI Gateway** (→ Amazon
Bedrock), with identity from **Amazon Cognito**, tools over **MCP**, untrusted
code isolated in **kata-containers + Firecracker** microVMs, and traces in
**Langfuse**.

---

## The build-up, module by module

Each module builds on the previous one. Every module has an architecture/flow
diagram and a step-by-step explanation in
**[LinkedINPost/diagrams/MODULE-FLOWS.md](./LinkedINPost/diagrams/MODULE-FLOWS.md)**.

### Core track (200 → 1000)

| # | Module | What it adds |
|---|---|---|
| 200 | [Strands Agents](./modules/200-strands-agents) | Foundation customer-service agent → Bedrock via the AI gateway |
| 300 | [Observability](./modules/300-observability-langfuse) | Langfuse tracing, grouped by session & persona |
| 500 | [Agent Tools (MCP)](./modules/500-agent-tools-mcp) | Real tools via Model Context Protocol + Milvus product RAG |
| 600 | [Multi-Agent (A2A)](./modules/600-multi-agent-a2a) | Orchestrator routes to Order/Product specialists |
| 700 | [Persona AuthZ](./modules/700-agentgateway-authz) | agentgateway authorizes each tool call by Cognito group |
| 800 | [Identity Propagation](./modules/800-multi-agent-authz) | Identity carried & enforced across every agent hop |
| 900 | [Sandboxed Code Exec](./modules/900-sandboxed-code-exec) | `run_python` in an air-gapped Firecracker microVM |
| 1000 | [Autonomous Coding Agent](./modules/1000-autonomous-coding-agent) | Git issue → Claude Code in a microVM → PR, no human credential |

### Advanced / production-hardening track (1100 → 1700)

| # | Module | What it adds |
|---|---|---|
| 1100 | [Guardrails](./modules/1100-guardrails) | Bedrock Guardrails on the model path — screens user input **and tool results** |
| 1200 | [Agent Memory](./modules/1200-agent-memory) | Short-term (DynamoDB) + long-term semantic (Milvus) memory, user-scoped |
| 1300 | [Evaluation Harness](./modules/1300-evaluation-harness) | LLM-as-judge regression suite incl. authz-negative cases |
| 1400 | [Resilience & Cost](./modules/1400-resilience-cost) | Per-persona rate limits, token budgets, retries, circuit breaking, fallback |
| 1500 | [Human-in-the-Loop](./modules/1500-human-approval) | High-impact actions pause for approval; agent can only propose |
| 1600 | [GitOps & Delivery](./modules/1600-gitops-delivery) | Argo CD + Rollouts canary gated by the 1300 evals |
| 1700 | [Multi-Region DR](./modules/1700-multiregion-dr) | Global tables, Route 53 failover, cross-region Bedrock failover |

---

## Architecture at a glance

```
UI (Cognito persona)
   │  Bearer JWT
   ▼
agentgateway ──(authz: per-persona, deny-by-default)──► MCP tools ─► DynamoDB
   │                                                     Milvus (RAG + memory)
   ├─► Orchestrator ─(A2A + token)─► Order / Product specialists
   │
   ├─► run_python ─► Firecracker microVM (air-gapped, no creds)
   │
   └─► Envoy AI Gateway ─► Amazon Bedrock (Nova / Claude)
                 │
            Langfuse (traces · sessions · personas)
```

Full per-module diagrams (PNG/SVG + Mermaid sources):
[`LinkedINPost/diagrams/`](./LinkedINPost/diagrams).

---

## Security themes baked into every layer

- **Identity propagates** across every hop — UI → orchestrator → specialist → MCP — not just at the front door.
- **Deny-by-default authz** at agentgateway; unauthorized tools are *hidden* from the agent, not merely blocked.
- **Hardware isolation**: untrusted, model-generated code runs in per-execution Firecracker microVMs.
- **Air-gapped sandboxes**: no network, no credentials; data injected out-of-band, never through the LLM.
- **Short-lived, per-run tokens** (coding agent) that are minted and revoked automatically.
- **Guardrails** screen prompt-injection (including via tool results) and mask PII.
- **Human-in-the-loop** for high-impact actions; the agent proposes, a human approves, a separate service executes.
- **Full observability** via Langfuse, and **evaluation** as a release gate.

---

## Repository layout

```
modules/      # the workshop labs (200–1700), each with README + code + k8s/policies
terraform/    # platform: EKS, Karpenter, gateways, Cognito, DynamoDB, Bedrock, Gitea, Langfuse …
LinkedINPost/ # architecture diagrams + per-module flow docs + summary writeup
```

## Getting started

1. Provision the platform with Terraform (see `terraform/`).
2. Work through the modules in order — each `modules/<name>/README.md` has apply
   steps and tests.
3. Interact via the chat UI (`modules/ui`), logging in as different Cognito
   personas (sales-analyst / support-associate) to see authorization in action.

> **Note:** Module `k8s.yaml` manifests reference container images that must be
> built and pushed to ECR, and some policy CRD `apiVersion`s should be pinned to
> the gateway/Argo versions you install — each module README flags these.

## Topics

`ai-agents` · `amazon-eks` · `aws` · `containers` · `kubernetes` · `pod-identity`
· `security` · `zero-trust`
