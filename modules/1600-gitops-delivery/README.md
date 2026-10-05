# 1600 — GitOps & progressive delivery (Argo CD + Argo Rollouts)

Replace hand-run `kubectl apply` with **Git as the source of truth**: Argo CD
reconciles every module's manifests from the repo, and **Argo Rollouts** ships
new agent images as **canaries** gated by the eval harness (1300) — so a bad
prompt or model change is caught on 10% of traffic, not 100%.

Builds on:
- All prior modules' `k8s.yaml` — they become the desired state Argo CD watches.
- **1300** — the eval Job is the canary's **analysis gate**: promote only if
  evals pass; auto-rollback if they regress.

## What changes operationally

| Before | After |
|---|---|
| `kubectl apply -f module/k8s.yaml` by hand | commit to Git → Argo CD syncs |
| image bump = `set image` + hope | Rollout canary: 10% → analysis → 50% → 100% |
| regressions found in prod | eval AnalysisTemplate fails the canary, auto-rollback |
| drift (someone `kubectl edit`s) | Argo CD flags OutOfSync and self-heals |

## Layout (App-of-Apps)

```
gitops/
  root-app.yaml            # Argo CD Application pointing at apps/
  apps/
    customer-agent.yaml    # Application -> modules/500.../k8s.yaml (Rollout)
    mcp-server.yaml
    guardrails-proxy.yaml  # module 1100
    approval-service.yaml  # module 1500
    ...
  rollouts/
    customer-agent-rollout.yaml   # Argo Rollout (canary strategy)
    analysis-eval.yaml            # AnalysisTemplate running the 1300 eval Job
```

Argo CD watches `gitops/apps/` (App-of-Apps): one root Application manages the
child Applications, each pointing at a module's manifests. Any change merged to
`main` is reconciled automatically.

## Progressive delivery

The `customer-agent` Deployment becomes an **Argo Rollout** with a canary
strategy: 10% → run the eval AnalysisTemplate → 50% → 100%, pausing for analysis
between steps. The `AnalysisTemplate` runs the module-1300 eval as a Job and
reads its exit code; a non-zero result (regression) **fails the canary and
auto-rolls-back** to the stable version.

## Apply (bootstrap)

```bash
# Install Argo CD + Argo Rollouts (once, usually via Terraform/Helm).
# Then register the root app — everything else flows from Git:
kubectl apply -f gitops/root-app.yaml
argocd app sync root-app
```

Thereafter: **don't `kubectl apply` modules** — commit to Git and let Argo CD
sync. To ship a new agent image: bump the tag in `customer-agent-rollout.yaml`,
commit; the canary + eval gate run automatically.

## Files
- `gitops/root-app.yaml` — App-of-Apps root Application.
- `gitops/apps/customer-agent.yaml` — example child Application.
- `gitops/rollouts/customer-agent-rollout.yaml` — canary Rollout.
- `gitops/rollouts/analysis-eval.yaml` — AnalysisTemplate wrapping the 1300 eval.

## Production deltas
- Protect `main` (reviews, signed commits); Argo CD applies whatever is merged —
  the branch *is* production access now.
- Separate the config repo from the app-code repo so an image build can bump the
  tag via PR without touching app source.
- Add notifications (Argo CD Notifications → Slack) on sync/health/degraded.
