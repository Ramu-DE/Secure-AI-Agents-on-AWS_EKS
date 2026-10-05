# 1700 — Multi-region / DR & Bedrock failover

Make the platform survive a **regional outage**: cross-region Bedrock failover,
global state (DynamoDB global tables + a replicated vector store), and
DNS/health-based traffic failover to a warm standby EKS cluster in a second
region.

Builds on and generalizes:
- **1400** — in-region model fallback (nova-pro → nova-lite). This module adds
  the *cross-region* dimension: when the whole primary region degrades, fail the
  model path over to Bedrock in region B.
- Every stateful dependency the modules introduced: orders + sessions (1200) +
  approvals (1500) in DynamoDB, and the Milvus vector store (500/1200).

## DR topology

```
                 Route 53 (health-checked, failover routing)
                     |                         |
         PRIMARY (us-east-1)           STANDBY (us-west-2)
         EKS + agents + gateways      EKS + agents + gateways (warm)
         Bedrock us-east-1            Bedrock us-west-2
                     \                       /
            DynamoDB GLOBAL TABLES (orders, sessions, approvals)
            Milvus: replicated / re-indexable from source of truth
```

- **Model**: each region's Envoy AI Gateway targets its *in-region* Bedrock, with
  a cross-region secondary. A region-level Bedrock problem fails over within the
  region first (1400), then — if the region itself is unhealthy — Route 53 shifts
  traffic to the standby cluster, which uses its own in-region Bedrock.
- **State**: DynamoDB **global tables** replicate orders/sessions/approvals
  bidirectionally (last-writer-wins), so the standby has live data. The Milvus
  catalog is rebuildable from its source of truth (the product data), so the
  standby re-indexes rather than depending on cross-region vector replication.
- **Traffic**: Route 53 failover routing with health checks on each region's
  gateway promotes the standby automatically when the primary health check fails.

## Strategy choice: warm standby

Warm standby (standby runs minimal replicas, scaled up on failover) balances
cost vs. RTO for a workshop-grade system. The README documents the alternatives
(pilot-light cheaper/slower, active-active costlier/fastest) so participants can
reason about the tradeoff.

| Strategy | RTO | Cost | When |
|---|---|---|---|
| Backup & restore | hours | $ | non-critical |
| Pilot light | ~10s of min | $$ | cost-sensitive |
| **Warm standby (this)** | minutes | $$$ | balanced |
| Active-active | seconds | $$$$ | critical, latency-global |

## Apply (IaC)

The DR resources are Terraform (`terraform/dr.tf` — sketched in
`terraform/dr.tf.example` here), because global tables, Route 53 health checks,
and the second EKS cluster are cloud infra, not in-cluster manifests:

```bash
# 1) make the state tables global (adds the us-west-2 replica)
# 2) stand up the standby EKS cluster + gateways (reuse the primary modules)
# 3) create Route 53 failover records with health checks on each gateway
terraform -chdir="$HOME/environment/terraform" apply -target=module.dr
```

The in-cluster piece is the gateway's cross-region backend + health check,
provided here as `policies/bedrock-failover.yaml`.

## Test (game day)

| Drill | Expected |
|---|---|
| Kill the primary region's gateway health check | Route 53 shifts traffic to standby within the TTL + health-check interval |
| Write an order in primary, read in standby | global-table replication makes it visible (eventually consistent) |
| Fail in-region Bedrock | 1400 fallback handles it without a region failover |
| Fail the whole primary region | standby serves; sessions (1200) continue from replicated state |

## Files
- `policies/bedrock-failover.yaml` — gateway backend with a cross-region
  secondary Bedrock endpoint + health check.
- `terraform/dr.tf.example` — global tables, Route 53 failover, standby cluster
  wiring (copy into `terraform/` and adapt).

## Production deltas
- Global tables are **last-writer-wins** — design writes to tolerate it
  (approvals should be idempotent; don't do cross-region read-modify-write).
- Test failover regularly (game days). An untested DR plan is a hypothesis.
- Watch replication lag; alert if the standby falls behind a threshold.
- Costs roughly double for warm standby — call this out to participants.
