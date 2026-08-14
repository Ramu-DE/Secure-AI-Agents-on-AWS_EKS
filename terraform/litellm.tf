################################################################################
# LiteLLM - Universal model-serving proxy
#
# LiteLLM sits in front of every model backend used in this workshop. Agents
# talk to LiteLLM over the OpenAI wire format; LiteLLM then routes to the
# appropriate Bedrock model based on the `model` name in the request. This
# turns "swap the backend" from a code change into a config change — the agent
# code path, SDK, and HTTP endpoint stay identical across models.
################################################################################

# Per-deployment master key. Used as:
#   - LiteLLM proxy masterkey (admin UI login + client Bearer token)
#   - LITELLM_API_KEY env var surfaced through the agent-config ConfigMaps
# A fresh random value is generated per `terraform apply`, so the key
# participants see never matches any value in the public repo.
resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}

# Password for the chart's bundled Postgres. Generated per deployment so no
# credential in the public repo matches what participants actually run with.
resource "random_password" "litellm_pg" {
  length  = 32
  special = false
}

locals {
  litellm_master_key = "sk-${random_password.litellm_master_key.result}"
}

resource "kubernetes_namespace_v1" "litellm" {
  metadata {
    name = "litellm"
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
  }
}

################################################################################
# IAM role for LiteLLM pods
#
# LiteLLM — not the agents — is the only in-cluster workload that invokes
# Bedrock directly. Pod Identity binds this role to the `litellm` service
# account, so the proxy pod gets AWS credentials automatically.
################################################################################

data "aws_iam_policy_document" "litellm_pod_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "litellm_pod" {
  name               = "${local.name}-litellm-pod"
  assume_role_policy = data.aws_iam_policy_document.litellm_pod_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "litellm_pod" {
  statement {
    sid    = "BedrockModelInvoke"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "litellm_pod" {
  name   = "litellm-pod-inline"
  role   = aws_iam_role.litellm_pod.id
  policy = data.aws_iam_policy_document.litellm_pod.json
}

resource "aws_eks_pod_identity_association" "litellm" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace_v1.litellm.metadata[0].name
  service_account = kubernetes_service_account_v1.litellm.metadata[0].name
  role_arn        = aws_iam_role.litellm_pod.arn
}

################################################################################
# LiteLLM Helm release
#
# Single proxy pod fronting several Bedrock models (Nova + Claude) via Pod
# Identity. Agents select a model by its alias (nova-lite, nova-pro,
# nova-micro, claude-sonnet, claude-haiku).
#
# Forwards its own spans to Langfuse so the proxy itself is visible as a
# tracing point — a bonus "model plane view" alongside the per-agent traces.
################################################################################

locals {
  litellm_values = {
    serviceAccount = {
      create = false
      name   = kubernetes_service_account_v1.litellm.metadata[0].name
    }

    # Pin LiteLLM image. Without this, Helm pulls the latest tag from the
    # chart's appVersion which can drift to tags that don't exist on ghcr.io.
    image = {
      repository = "ghcr.io/berriai/litellm-database"
      tag        = "main-v1.82.3"
      pullPolicy = "IfNotPresent"
    }

    # Pin Postgres image. Bitnami removed older tags from docker.io/bitnami,
    # so use the bitnamilegacy mirror which still hosts versioned tags.
    postgresql = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
        tag        = "17.3.0-debian-12-r1"
      }
      auth = { username = "litellm", password = random_password.litellm_pg.result }
    }

    # Chart expects a master key; pulled from random_password above so every
    # deployment gets a unique value and nothing in the public repo matches it.
    # Doubles as the login for the admin UI at /ui.
    masterkey = local.litellm_master_key

    # Resource requests so Karpenter provisions adequate nodes and the pod
    # doesn't get OOMKilled during Prisma migrations or under load.
    resources = {
      requests = { cpu = "500m", memory = "2Gi" }
      limits   = { memory = "2Gi" }
    }

    # Give the migration Job more time and retries — PG may take a minute
    # to accept connections on cold starts (Karpenter node provisioning).
    migrationJob = {
      enabled = false
    }

    # The chart deploys a bundled Postgres by default, which backs the UI's
    # request logs, virtual keys, and spend views. We leave it on so the
    # "Explore the LiteLLM UI" step has something to show.

    proxy_config = {
      model_list = [
        {
          model_name = "nova-lite"
          litellm_params = {
            model           = "bedrock/us.amazon.nova-2-lite-v1:0"
            aws_region_name = local.region
          }
        },
        {
          model_name = "nova-pro"
          litellm_params = {
            model           = "bedrock/us.amazon.nova-pro-v1:0"
            aws_region_name = local.region
          }
        },
        {
          model_name = "nova-micro"
          litellm_params = {
            model           = "bedrock/us.amazon.nova-micro-v1:0"
            aws_region_name = local.region
          }
        },
        {
          model_name = "claude-sonnet"
          litellm_params = {
            model           = "bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0"
            aws_region_name = local.region
          }
        },
        {
          model_name = "claude-haiku"
          litellm_params = {
            model           = "bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0"
            aws_region_name = local.region
          }
        },
      ]

      litellm_settings = {
        # Forward LiteLLM's own spans into the workshop Langfuse project.
        success_callback = ["langfuse"]
        failure_callback = ["langfuse"]
      }
    }

    # Wire Langfuse env vars so the callback above has somewhere to send to.
    envVars = {
      LANGFUSE_PUBLIC_KEY = local.langfuse_pk
      LANGFUSE_SECRET_KEY = local.langfuse_sk
      LANGFUSE_HOST       = "http://langfuse-web.langfuse.svc.cluster.local:3000"
    }

    service = {
      type = "ClusterIP"
      port = 4000
    }
  }
}

resource "helm_release" "litellm" {
  name       = "litellm"
  repository = "oci://ghcr.io/berriai"
  chart      = "litellm-helm"
  namespace  = kubernetes_namespace_v1.litellm.metadata[0].name
  wait       = false
  timeout    = 600

  values = [yamlencode(local.litellm_values)]

  depends_on = [
    aws_eks_pod_identity_association.litellm,
    # Needs a Karpenter-provisioned general-purpose node to schedule on.
    null_resource.karpenter_general_nodepool,
  ]
}

################################################################################
# Ingress — separate ALB for the LiteLLM UI + API
#
# Workshop participants use a browser-based VSCode IDE and can't easily reach
# port-forwarded services, so we expose LiteLLM on its own ALB. Langfuse has
# its own ALB too; giving each service a dedicated load balancer avoids the
# path-rewrite issues that come with sharing one (both apps want root paths
# for their static assets).
#
# The UI is protected only by the generated master key (surfaced through the
# agent API key — fine for workshop accounts that get reaped after the event,
# not suitable for anything long-lived.
################################################################################

resource "kubernetes_ingress_v1" "litellm" {
  metadata {
    name      = "litellm"
    namespace = kubernetes_namespace_v1.litellm.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"        = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"   = "ip"
      "alb.ingress.kubernetes.io/listen-ports"  = "[{\"HTTP\":80}]"
      "alb.ingress.kubernetes.io/inbound-cidrs" = join(",", var.allowed_ingress_cidrs)
    }
  }

  spec {
    ingress_class_name = "alb"
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "litellm"
              port {
                number = 4000
              }
            }
          }
        }
      }
    }
  }

  # Also depend on wait_for_lb_controller: creating this Ingress invokes the LB
  # controller's validating webhook, which must have ready endpoints (see the
  # chainlit-ui ingress for the full rationale).
  depends_on = [
    helm_release.litellm,
    null_resource.wait_for_lb_controller,
  ]
}
