################################################################################
# Gitea (module 1000) — in-cluster git host for the autonomous coding agent.
#
# Issues + PRs + webhooks. Built-in local auth (Cognito federation is an
# out-of-scope extension). ROOT_URL is the Gitea CloudFront domain so human
# clone/links are correct; the agent + webhook use the in-cluster ClusterIP
# (gitea-http.gitea.svc.cluster.local:3000). SQLite + single replica — a
# workshop-simple footprint. Image mirrored to ECR (codebuild-images.tf).
################################################################################

resource "kubernetes_namespace_v1" "gitea" {
  metadata {
    name = "gitea"
    labels = {
      "kubernetes.io/metadata.name" = "gitea"
    }
  }
  depends_on = [module.eks]
}

# Random admin password per apply (never matches the public repo).
resource "random_password" "gitea_admin" {
  length  = 24
  special = false
}

resource "helm_release" "gitea" {
  name       = "gitea"
  repository = "https://dl.gitea.com/charts/"
  chart      = "gitea"
  version    = "12.1.3" # pin; appVersion Gitea 1.24.3 (matches the mirrored gitea:1.24.3 image)
  namespace  = kubernetes_namespace_v1.gitea.metadata[0].name
  timeout    = 900

  values = [yamlencode({
    # Mirror the image to ECR (repo convention: no docker.io pulls at runtime).
    image = {
      registry   = local.ecr_registry
      repository = "gitea"
      tag        = "1.24.3"
      # Chart default rootless=true -> the pod pulls "gitea:1.24.3-rootless".
      # codebuild-images.tf mirrors that rootless tag (alongside the plain tag)
      # into ECR. If that mirror is missing, gitea ImagePullBackOffs and the Helm
      # wait times out (context deadline exceeded).
    }
    service = {
      http = { type = "ClusterIP", port = 3000 }
      ssh  = { type = "ClusterIP", port = 22 }
    }
    # SQLite: disable the chart's bundled HA deps.
    "postgresql-ha"  = { enabled = false }
    postgresql       = { enabled = false }
    "redis-cluster"  = { enabled = false }
    "valkey-cluster" = { enabled = false }
    persistence      = { enabled = true, size = "10Gi" }
    gitea = {
      admin = {
        username = "workshop-admin"
        password = random_password.gitea_admin.result
        email    = "admin@example.com"
      }
      config = {
        database = { DB_TYPE = "sqlite3" }
        server = {
          ROOT_URL   = "https://${aws_cloudfront_distribution.gitea.domain_name}/"
          DOMAIN     = aws_cloudfront_distribution.gitea.domain_name
          SSH_DOMAIN = aws_cloudfront_distribution.gitea.domain_name
        }
        service = {
          DISABLE_REGISTRATION = true
          REQUIRE_SIGNIN_VIEW  = false
        }
        # Allow the in-cluster webhook target (private address).
        webhook = { ALLOWED_HOST_LIST = "*" }
      }
    }
  })]

  depends_on = [
    kubernetes_namespace_v1.gitea,
    null_resource.build_images, # image must be mirrored to ECR first
  ]
}

# Register gitea pod IPs into the Terraform-managed target group.
resource "null_resource" "gitea_tgb" {
  triggers = {
    cluster_name     = module.eks.cluster_name
    region           = local.region
    target_group_arn = aws_lb_target_group.gitea.arn
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region}
      kubectl apply -f - <<'YAML'
      apiVersion: elbv2.k8s.aws/v1beta1
      kind: TargetGroupBinding
      metadata:
        name: gitea-http
        namespace: gitea
      spec:
        serviceRef:
          name: gitea-http
          port: 3000
        targetGroupARN: ${self.triggers.target_group_arn}
        targetType: ip
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} || exit 0
      kubectl delete targetgroupbinding gitea-http -n gitea --ignore-not-found --wait=true || true
    EOT
  }

  depends_on = [
    aws_lb_target_group.gitea,
    helm_release.gitea,
    null_resource.wait_for_lb_controller,
  ]
}
