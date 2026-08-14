
################################################################################
# Langfuse - LLM Observability
################################################################################

# Per-apply admin login for the Langfuse UI. LANGFUSE_INIT_* seeds the user on
# FIRST boot only (an existing database keeps its stored credentials), which is
# fine here: every workshop account provisions fresh. Surfaced to participants
# via the langfuse_* outputs -> IDE env vars (see cdk/resources/bootstrap.sh),
# mirroring the chat-UI and Gitea credential flow.
resource "random_password" "langfuse_admin" {
  length  = 20
  special = false
}

locals {
  langfuse_admin_email = "admin@workshop.local"
  langfuse_values = {
    langfuse = {
      salt     = { value = "workshop-salt-2026" }
      nextauth = { secret = { value = "workshop-nextauth-secret-2026" } }
      # Required for LLM-as-a-Judge: Langfuse encrypts stored LLM Connection
      # API keys at rest with this key. Without it, saving an LLM connection
      # in the evaluation lab fails with "Missing environment variable:
      # ENCRYPTION_KEY". Must be 256 bits / 64 hex chars (openssl rand -hex 32).
      encryptionKey = { value = "f2e97cc15226ca3f85c548df1ee50aad82d38baae4e8e3e6a0dc21826c68dbc2" }
      # Applies to ALL langfuse pods (web AND worker). The LLM-as-a-Judge
      # connection is validated by langfuse-web, but the judge HTTP call
      # itself is made by langfuse-worker — both pods enforce Langfuse's
      # SSRF guard, which blocks RFC1918 / cluster-internal hosts by
      # default and would otherwise fail with "Blocked IP address detected".
      # Scoped to the LiteLLM service hostname only.
      additionalEnv = [
        { name = "LANGFUSE_LLM_CONNECTION_WHITELISTED_HOST", value = "litellm.litellm.svc.cluster.local" },
      ]
      resources = {
        limits   = { cpu = "2", memory = "4Gi" }
        requests = { cpu = "2", memory = "4Gi" }
      }
      # No Ingress. Langfuse is published by a private ALB behind CloudFront
      # (langfuse-cloudfront.tf), so participants reach it over HTTPS and the
      # load balancer has no public address. The chart's Ingress would create an
      # internet-facing ALB on plaintext HTTP instead.
      ingress = {
        enabled = false
      }
      web = {
        livenessProbe = {
          initialDelaySeconds = 300
          failureThreshold    = 30
          periodSeconds       = 30
        }
        readinessProbe = {
          initialDelaySeconds = 60
          failureThreshold    = 30
          periodSeconds       = 15
        }
        pod = {
          additionalEnv = [
            { name = "LANGFUSE_INIT_ORG_ID", value = "anycompany-shop" },
            { name = "LANGFUSE_INIT_ORG_NAME", value = "AnyCompany Shop" },
            { name = "LANGFUSE_INIT_PROJECT_ID", value = "customer-agent" },
            { name = "LANGFUSE_INIT_PROJECT_NAME", value = "Customer Agent" },
            { name = "LANGFUSE_INIT_PROJECT_PUBLIC_KEY", value = local.langfuse_pk },
            { name = "LANGFUSE_INIT_PROJECT_SECRET_KEY", value = local.langfuse_sk },
            { name = "LANGFUSE_INIT_USER_EMAIL", value = local.langfuse_admin_email },
            { name = "LANGFUSE_INIT_USER_NAME", value = "Workshop Admin" },
            { name = "LANGFUSE_INIT_USER_PASSWORD", value = random_password.langfuse_admin.result },
            { name = "TELEMETRY_ENABLED", value = "false" },
          ]
        }
      }
    }
    postgresql = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
        tag        = "17.3.0-debian-12-r1"
      }
      auth = { username = "langfuse", password = "langfuse-workshop-2025" }
    }
    clickhouse = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/clickhouse"
        tag        = "25.2.1-debian-12-r0"
      }
      auth         = { password = "clickhouse-workshop-2025" }
      shards       = 1
      replicaCount = 1
      resources = {
        limits   = { cpu = "2", memory = "8Gi" }
        requests = { cpu = "2", memory = "8Gi" }
      }
      zookeeper = {
        image = {
          registry   = "docker.io"
          repository = "bitnamilegacy/zookeeper"
          tag        = "3.9.3-debian-12-r8"
        }
        replicaCount = 1
        resources = {
          limits   = { cpu = "2", memory = "4Gi" }
          requests = { cpu = "2", memory = "4Gi" }
        }
      }
    }
    redis = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/valkey"
        tag        = "8.0.2-debian-12-r2"
      }
      auth = { password = "redis-workshop-2025" }
      primary = {
        resources = {
          limits   = { cpu = "1", memory = "2Gi" }
          requests = { cpu = "1", memory = "2Gi" }
        }
      }
    }
    s3 = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/minio"
        tag        = "2024.12.18-debian-12-r1"
      }
      auth = { rootPassword = "minio-workshop-2025" }
      resources = {
        limits   = { cpu = "2", memory = "4Gi" }
        requests = { cpu = "2", memory = "4Gi" }
      }
    }
  }
}

# Step 1: Install with web/worker replicas=0 (infra only)
resource "helm_release" "langfuse" {
  name             = "langfuse"
  repository       = "https://langfuse.github.io/langfuse-k8s"
  chart            = "langfuse"
  namespace        = "langfuse"
  create_namespace = true
  wait             = false
  timeout          = 600

  values = [yamlencode(merge(local.langfuse_values, {
    langfuse = merge(local.langfuse_values.langfuse, {
      web    = merge(local.langfuse_values.langfuse.web, { replicas = 0 })
      worker = { replicas = 0 }
    })
  }))]

  # Karpenter must be ready to provision general-purpose nodes before the
  # langfuse infra pods (ClickHouse 8Gi, PG, Redis, MinIO) can schedule — they
  # do not fit on the system MNG. Without this the langfuse_wait_and_enable
  # 5-minute ClickHouse timeout can start counting before any node exists.
  depends_on = [
    time_sleep.wait_60_seconds,
    null_resource.karpenter_general_nodepool,
  ]
}

# Step 2: Wait for infra pods, then scale up web/worker
resource "null_resource" "langfuse_wait_and_enable" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}

      # Ensure web/worker are at 0 replicas before waiting for infra.
      # Helm values set replicas=0 but upgrades may not re-apply if release exists.
      echo "Scaling web and worker to 0..."
      kubectl scale deploy -n langfuse langfuse-web --replicas=0 2>/dev/null || true
      kubectl scale deploy -n langfuse langfuse-worker --replicas=0 2>/dev/null || true

      echo "Waiting for ClickHouse pods to be scheduled..."
      for i in $(seq 1 10); do
        PODS=$(kubectl get pods -l app.kubernetes.io/name=clickhouse -n langfuse --no-headers 2>/dev/null | wc -l)
        if [ "$PODS" -gt 0 ]; then
          echo "ClickHouse pods found."
          break
        fi
        echo "Attempt $i/10: No ClickHouse pods yet, waiting 30s..."
        sleep 30
      done

      echo "Waiting for ClickHouse to become ready..."
      for i in $(seq 1 5); do
        if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=clickhouse -n langfuse --timeout=180s 2>/dev/null; then
          echo "ClickHouse is ready."
          break
        fi
        echo "Attempt $i/5: ClickHouse not ready, deleting pods to force reschedule..."
        kubectl delete pod -l app.kubernetes.io/name=clickhouse -n langfuse --ignore-not-found
        sleep 30
      done

      # Verify ClickHouse Service is reachable on port 9000 (TCP, used by migrations)
      # Must test from outside the CH pod — same network path langfuse-web uses.
      echo "Verifying ClickHouse Service is reachable on port 9000..."
      for i in $(seq 1 30); do
        if kubectl run ch-check --rm -i -n langfuse --image=public.ecr.aws/docker/library/busybox --restart=Never -- \
          sh -c "nc -z langfuse-clickhouse 9000" 2>/dev/null; then
          echo "ClickHouse Service port 9000 is reachable."
          break
        fi
        kubectl delete pod ch-check -n langfuse --ignore-not-found 2>/dev/null
        if [ "$i" = "30" ]; then
          echo "ERROR: ClickHouse Service not reachable after 5 minutes"
          exit 1
        fi
        echo "Attempt $i/30: ClickHouse Service not reachable yet, waiting 10s..."
        sleep 10
      done

      echo "Waiting for PostgreSQL to become ready..."
      kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n langfuse --timeout=300s

      # Verify PG is actually accepting connections, not just "pod ready".
      # Prisma migrations will fail fast (P1001) if PG isn't answering yet.
      echo "Verifying PostgreSQL is accepting connections..."
      for i in $(seq 1 30); do
        if kubectl exec -n langfuse langfuse-postgresql-0 -- pg_isready -U postgres 2>&1 | grep -q "accepting connections"; then
          echo "PostgreSQL is accepting connections."
          break
        fi
        if [ "$i" = "30" ]; then
          echo "ERROR: PostgreSQL not accepting connections after 5 minutes"
          exit 1
        fi
        echo "Attempt $i/30: PG not accepting yet, waiting 10s..."
        sleep 10
      done

      echo "Waiting for Redis to become ready..."
      kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=redis -n langfuse --timeout=300s

      echo "All infra pods ready. Scaling up langfuse-web (runs DB migrations)..."
      kubectl scale deploy -n langfuse langfuse-web --replicas=1

      # Wait for web to finish migrations and become ready.
      # Probes are configured with ~20 min of tolerance so migrations on a
      # cold ClickHouse won't get killed mid-run.
      echo "Waiting for langfuse-web rollout to complete (up to 20 min)..."
      if ! kubectl rollout status deploy/langfuse-web -n langfuse --timeout=20m; then
        echo "langfuse-web did not become ready. Attempting dirty-migration recovery..."

        # Dirty state recovery: clear the dirty flag in ClickHouse and restart web.
        # Harmless if there are no dirty rows.
        CH_PW=$(kubectl get secret -n langfuse langfuse-clickhouse -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "clickhouse-workshop-2025")
        kubectl exec -n langfuse langfuse-clickhouse-shard0-0 -- \
          clickhouse-client --user default --password "$CH_PW" \
          --query "ALTER TABLE schema_migrations UPDATE dirty = 0 WHERE dirty = 1" 2>&1 || true

        echo "Deleting crashed web pod to force restart..."
        kubectl delete pod -n langfuse -l app=web --ignore-not-found --wait=false

        echo "Retrying langfuse-web rollout (up to 15 min)..."
        kubectl rollout status deploy/langfuse-web -n langfuse --timeout=15m
      fi

      echo "langfuse-web ready. Scaling up langfuse-worker..."
      kubectl scale deploy -n langfuse langfuse-worker --replicas=1

      echo "Waiting for langfuse-worker rollout to complete (up to 10 min)..."
      kubectl rollout status deploy/langfuse-worker -n langfuse --timeout=10m

      echo "Langfuse is fully running."
    EOT
  }

  depends_on = [helm_release.langfuse]
}


################################################################################
# Seed Langfuse model prices (so the dashboard shows cost, not blank)
#
# Langfuse computes cost = token usage x a matching model definition's price.
# It matches on the `model` string the CLIENT sends, which here is the friendly
# ALIAS the agents pass (nova-lite, claude-sonnet, ...), NOT the real Bedrock ID
# the Envoy AI Gateway rewrites to on the wire. None of these aliases are in
# Langfuse's built-in price list, so without this every generation shows blank
# cost. We POST one model definition per alias via the public API.
#
# Prices are per-TOKEN USD, sourced from the LiteLLM community cost map for the
# real Bedrock model each alias maps to (us-region rate where it differs). See
# the alias -> model mapping in manifests/envoy-ai-gateway-bedrock.yaml. RE-VERIFY
# against the live AWS Bedrock pricing page if absolute cost accuracy matters;
# the workshop's point is that cost SHOWS UP, keyed to the friendly alias.
#
# matchPattern is an anchored, case-insensitive regex on the alias so it matches
# exactly (e.g. `nova-lite` does not also swallow a future `nova-lite-v2`).
#
# Separate resource (not folded into langfuse_wait_and_enable) with a triggers
# hash on the price list, so editing a price re-runs ONLY this seed in seconds
# rather than the 20-minute infra wait above.
locals {
  # alias => [input_price_per_token, output_price_per_token] (USD).
  # Strings, not numbers: interpolated verbatim into the JSON body, so Terraform
  # never reformats a tiny decimal into scientific notation. Emitted UNQUOTED in
  # the body, so they land as JSON numbers.
  langfuse_model_prices = {
    "nova-micro"    = ["0.000000035", "0.00000014"]
    "nova-lite"     = ["0.00000033", "0.00000275"] # gateway maps to Nova 2 Lite (us)
    "nova-pro"      = ["0.0000008", "0.0000032"]
    "claude-haiku"  = ["0.000001", "0.000005"]
    "claude-sonnet" = ["0.000003", "0.000015"]
  }
}

resource "null_resource" "langfuse_seed_model_prices" {
  triggers = {
    # Re-run whenever the price list changes.
    prices = jsonencode(local.langfuse_model_prices)
    pk     = local.langfuse_pk
    sk     = local.langfuse_sk
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${local.region}

      # POST each model definition from INSIDE the cluster (the langfuse-web
      # Service is ClusterIP-only). One short-lived curl pod per call, talking to
      # the same in-cluster Service the agents/collector use.
      LF="http://langfuse-web.langfuse.svc.cluster.local:3000/api/public/models"
      AUTH="${local.langfuse_pk}:${local.langfuse_sk}"

      # Best-effort: a failed price seed must never abort the whole apply
      # (pricing is a dashboard nicety, not a hard dependency). Each seed warns
      # and continues. POSTing the same modelName+matchPattern again is
      # effectively idempotent for the workshop; the newest definition applies to
      # subsequent generations, so re-runs are harmless.
      seed() {
        local alias="$1" in_price="$2" out_price="$3"
        # Anchored, case-insensitive exact match on the alias the agents send.
        # \$ is a literal $ (regex end-anchor); in/out prices are unquoted so
        # they land as JSON numbers, not strings.
        local body="{\"modelName\":\"$alias\",\"matchPattern\":\"(?i)^$alias\$\",\"unit\":\"TOKENS\",\"inputPrice\":$in_price,\"outputPrice\":$out_price}"
        echo "Seeding price for $alias ($in_price in / $out_price out per token)..."
        kubectl run "lf-seed-$alias" --rm -i --restart=Never -n langfuse \
          --image=curlimages/curl -- \
          curl -sS -u "$AUTH" -H 'Content-Type: application/json' \
          -X POST "$LF" -d "$body" \
          || echo "  WARNING: failed to seed price for $alias (continuing)"
        echo
      }

      %{~for alias, price in local.langfuse_model_prices~}
      seed "${alias}" "${price[0]}" "${price[1]}"
      %{~endfor~}

      echo "Langfuse model prices seeded."
    EOT
  }

  # langfuse-web must be serving the API before we POST models.
  depends_on = [null_resource.langfuse_wait_and_enable]
}


################################################################################
# Agent Configuration ConfigMap
################################################################################

resource "kubernetes_config_map_v1" "agent_config" {
  metadata {
    name      = "agent-config"
    namespace = "default"
  }

  data = {
    # Model gateway the agents talk to (OpenAI-compatible, in front of Bedrock).
    # Default: Envoy AI Gateway. The data-plane Service name is pinned to
    # "ai-gateway" via the EnvoyProxy envoyService.name field (see
    # manifests/envoy-ai-gateway-bedrock.yaml); it lives in the Envoy Gateway
    # controller namespace (envoy-gateway-system), NOT envoy-ai-gateway-system.
    MODEL_BASE_URL = "http://ai-gateway.envoy-gateway-system.svc.cluster.local/v1"
    MODEL_ID       = "nova-lite"
    MODEL_API_KEY  = "not-needed" # Envoy AI Gateway auths to Bedrock via Pod Identity, not a client key.

    # LiteLLM stays deployed as an alternate OpenAI-compatible gateway. To point
    # the agents back at it, set MODEL_BASE_URL to LITELLM_BASE_URL and
    # MODEL_API_KEY to LITELLM_API_KEY.
    LITELLM_BASE_URL = "http://litellm.litellm.svc.cluster.local:4000/v1"
    LITELLM_API_KEY  = local.litellm_master_key

    # LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY are NOT here: they are
    # credentials and live in the langfuse-keys Secret below, which the agent
    # Deployments read with secretKeyRef. The base URL is not a credential, so
    # it stays in the ConfigMap.
    LANGFUSE_BASE_URL = "http://langfuse-web.langfuse.svc.cluster.local:3000"
    MILVUS_URI        = "http://milvus.milvus.svc.cluster.local:19530"
    # Order data source (DynamoDB). Agents read the table name from here and
    # get credentials via the "agent" service account's Pod Identity.
    ORDERS_TABLE = aws_dynamodb_table.orders.name
    AWS_REGION   = local.region

    # OpenTelemetry export target for the agents' `opentelemetry-instrument`
    # launcher (Dockerfile CMD). Without an endpoint it defaults to
    # localhost:4318 and the FastAPI request span — the trace ROOT that names
    # the Langfuse trace — is dropped (connection refused), leaving traces with
    # an empty name and orphaned observations. Point it at the shared OTel
    # Collector (the single authenticated egress to Langfuse; see
    # observability.tf), which converges agent + Envoy AI Gateway + agentgateway
    # traces. Metrics/logs exporters are disabled because the collector runs a
    # traces-only pipeline (otherwise the launcher 404s exporting metrics).
    # OTEL_SERVICE_NAME is a shared default; a Deployment may override it in its
    # own env: for a per-agent service name.
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://agentgateway-traces-collector.telemetry.svc.cluster.local:4318"
    OTEL_SERVICE_NAME           = "customer-agent"
    OTEL_METRICS_EXPORTER       = "none"
    OTEL_LOGS_EXPORTER          = "none"
  }

  depends_on = [module.eks]
}

################################################################################
# Langfuse API keys (Secret, not ConfigMap)
################################################################################

# The agents authenticate to Langfuse with a project key pair. Credentials do
# not belong in a ConfigMap, which any pod with get access can read in plain
# text, so they live here and the agent Deployments pull them with secretKeyRef.
#
# The values are the fixed workshop project keys (see local.langfuse_pk/sk in
# gateways.tf). They are seeded into Langfuse itself by LANGFUSE_INIT_PROJECT_*
# above and reused by litellm.tf and the OTel collector's Basic-auth header, so
# all four consumers must agree. A Kubernetes Secret keeps them out of pod
# config while staying a single source of truth; a real deployment would
# generate the pair per environment instead of pinning it.
resource "kubernetes_secret_v1" "langfuse_keys" {
  metadata {
    name      = "langfuse-keys"
    namespace = "default"
  }
  data = {
    LANGFUSE_PUBLIC_KEY = local.langfuse_pk
    LANGFUSE_SECRET_KEY = local.langfuse_sk
  }
  depends_on = [module.eks]
}
