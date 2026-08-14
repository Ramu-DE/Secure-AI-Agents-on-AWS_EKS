
################################################################################
# EKS Blueprints Addons
################################################################################

module "eks_blueprints_addons" {
  depends_on = [time_sleep.wait_60_seconds]
  source     = "aws-ia/eks-blueprints-addons/aws"
  version    = "1.23.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # AWS Load Balancer Controller — provisions the ALBs the workshop ingresses
  # (LiteLLM, chat UI, Langfuse) depend on. EKS Auto Mode provided ALB natively;
  # a standard cluster needs this controller.
  #
  # Pinned to the system MNG: it's a cluster-critical controller and must not
  # depend on Karpenter (which it is unrelated to) for a node to run on. The
  # system MNG is the only node group with this label.
  #
  # vpcId + region are passed EXPLICITLY. Without them the controller tries to
  # introspect the VPC ID from EC2 instance metadata (IMDS) and crash-loops with
  # "failed to fetch VPC ID from instance metadata: EC2MetadataError ... status
  # code: 401" — the pod can't reach IMDSv2 through the extra network hop. Giving
  # it vpcId/region directly skips IMDS introspection entirely.
  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    values = [yamlencode({
      nodeSelector = { "workshop.io/node-role" = "system" }
      vpcId        = module.vpc.vpc_id
      region       = local.region
    })]
  }

  # cert-manager — required by the ADOT operator addon (its admission webhooks
  # need cert-manager-issued certs). Installed here so the adot addon can depend
  # on it. Pinned to the system MNG (all three deployments: controller, webhook,
  # cainjector) for the same reason as the LB controller.
  enable_cert_manager = true
  cert_manager = {
    values = [yamlencode({
      nodeSelector = { "workshop.io/node-role" = "system" }
      webhook      = { nodeSelector = { "workshop.io/node-role" = "system" } }
      cainjector   = { nodeSelector = { "workshop.io/node-role" = "system" } }
    })]
  }

  tags = local.tags
}

################################################################################
# ADOT - AWS Distro for OpenTelemetry operator (EKS managed addon)
#
# Installs the operator only; it does not collect telemetry until an
# OpenTelemetryCollector CR is created (workshop content). Two ordering
# prerequisites, both enforced by null_resource.wait_for_lb_controller below:
#
#   1. cert-manager must be running — the ADOT operator's admission webhooks
#      need cert-manager-issued certs.
#   2. The AWS Load Balancer Controller must be READY. It registers a
#      cluster-wide mutating webhook on Services (mservice.elbv2.k8s.aws) with
#      failurePolicy=Fail; until the controller has ready endpoints, ANY Service
#      creation — including the ADOT operator's — is rejected with
#      "no endpoints available for service aws-load-balancer-webhook-service".
#
# We wait on actual readiness (condition-based) instead of a blind sleep, which
# previously raced the controller rollout and failed the addon create.
################################################################################

resource "null_resource" "wait_for_lb_controller" {
  triggers = {
    cluster_name = module.eks.cluster_name
    region       = local.region
  }

  provisioner "local-exec" {
    # The CodeBuild Terraform Runner's default shell is /bin/sh (dash), which
    # rejects `set -o pipefail`. Force bash, matching langfuse.tf.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region}
      echo "Waiting for AWS Load Balancer Controller to be Available..."
      kubectl rollout status deploy/aws-load-balancer-controller -n kube-system --timeout=10m
      echo "Waiting for cert-manager webhook to be Available..."
      kubectl rollout status deploy/cert-manager-webhook -n cert-manager --timeout=10m
    EOT
  }

  depends_on = [module.eks_blueprints_addons]
}

resource "aws_eks_addon" "adot" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "adot"
  addon_version = var.adot_addon_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    null_resource.wait_for_lb_controller,
  ]

  tags = local.tags
}

# NOTE: the "alb" IngressClass is NOT defined here. The AWS Load Balancer
# Controller Helm chart creates it automatically (createIngressClassResource +
# ingressClass=alb are chart defaults), so a separate kubernetes_ingress_class_v1
# resource collides with "ingressclasses ... alb already exists". The litellm /
# chat UI / langfuse ingresses reference ingressClassName "alb"; they depend on
# module.eks_blueprints_addons (which installs the controller) to order against
# the controller-created class.

################################################################################
# EBS CSI driver - IAM role + Pod Identity association
#
# The aws-ebs-csi-driver managed addon (base.tf) needs IAM permissions to
# create/attach EBS volumes. Pod Identity binds this role to the driver's
# controller service account.
################################################################################

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

################################################################################
# EKS - StorageClass
################################################################################

resource "kubernetes_storage_class_v1" "ebs_sc" {
  metadata {
    name = "ebs-sc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  # ebs.csi.aws.com is the standard EBS CSI driver addon provisioner. (Auto Mode
  # used ebs.csi.eks.amazonaws.com, which does not exist on a regular cluster.)
  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  # depends_on module.eks (not just the EBS-CSI pod-identity assoc) so this
  # StorageClass is created only AFTER the cluster-creator access-entry
  # association (from enable_cluster_creator_admin_permissions) is in effect.
  # Otherwise, on a first apply, the kubernetes provider can race that
  # association and hit "storageclasses.storage.k8s.io is forbidden" — which
  # leaves the cluster with no default StorageClass, so every PVC (langfuse
  # ClickHouse/Postgres/Redis, milvus, gitea) stays Pending and Karpenter never
  # provisions nodes for them.
  depends_on = [aws_eks_pod_identity_association.ebs_csi, module.eks]
}


################################################################################
# Milvus - Vector Database
################################################################################

resource "helm_release" "milvus" {
  name             = "milvus"
  repository       = "https://zilliztech.github.io/milvus-helm"
  chart            = "milvus"
  namespace        = "milvus"
  create_namespace = true
  wait             = false
  timeout          = 600

  values = [yamlencode({
    cluster = { enabled = false }

    standalone = {
      resources = {
        requests = { cpu = "500m", memory = "2Gi" }
        limits   = { memory = "4Gi" }
      }
      persistence = {
        enabled = true
        persistentVolumeClaim = {
          storageClass = "ebs-sc"
          size         = "10Gi"
        }
      }
    }

    etcd = {
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/etcd"
        tag        = "3.5.21-debian-12-r0"
      }
      replicaCount = 1
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
      persistence = {
        enabled      = true
        storageClass = "ebs-sc"
        size         = "10Gi"
      }
    }

    minio = {
      enabled = true
      mode    = "standalone"
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
      persistence = {
        enabled      = true
        storageClass = "ebs-sc"
        size         = "10Gi"
      }
    }

    pulsarv3 = { enabled = false }
    pulsar   = { enabled = false }
    kafka    = { enabled = false }
  })]

  depends_on = [
    kubernetes_storage_class_v1.ebs_sc,
    time_sleep.wait_60_seconds,
    # Karpenter must be ready to provision general-purpose nodes — this stack
    # does not fit on the system MNG.
    null_resource.karpenter_general_nodepool,
  ]
}
