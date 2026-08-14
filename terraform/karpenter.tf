################################################################################
# Karpenter - self-managed node autoscaling
#
# Replaces EKS Auto Mode's built-in Karpenter. The submodule provisions the
# supporting AWS resources (node IAM role + instance profile, controller IAM
# role, Pod Identity association); the Helm release runs the controller on the
# system managed node group; a general-purpose NodePool provides on-demand
# capacity for the agents and the support stack; and a dedicated kata-fc pool
# provides Firecracker microVM isolation for sandboxed workloads (see
# manifests/). Native spot-termination handling (the SQS interruption queue +
# EventBridge rules) is DISABLED — the pools are on-demand only (see
# enable_spot_termination below).
################################################################################

# Public ECR auth token for pulling the Karpenter OCI chart.
data "aws_ecrpublic_authorization_token" "token" {
  region = "us-east-1"
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.24.0"

  cluster_name = module.eks.cluster_name

  # Node IAM role name must match the role referenced by the EC2NodeClass below.
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = "${local.name}-karpenter-node"
  create_pod_identity_association = true

  # Create the controller policy as an INLINE role policy (10,240 char limit)
  # instead of a standalone managed policy (6,144 char limit). The cluster name
  # is interpolated into many scoped EC2 ARN conditions, which pushes the
  # rendered policy past 6,144 and fails with
  # "LimitExceeded: Cannot exceed quota for PolicySize: 6144".
  enable_inline_policy = true

  # SSM access so nodes can be managed / debugged via Session Manager.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Disable native spot-termination handling (the SQS interruption queue + its
  # EventBridge rules/targets). Both NodePools below are ON-DEMAND ONLY, so there
  # are no spot interruptions to handle and the queue provides no value.
  #
  # This also removes a transient provisioning failure: the AWS provider's
  # aws_cloudwatch_event_target does not retry the post-create read against
  # EventBridge's eventually-consistent ListTargetsByRule API, so the target's
  # read-after-create intermittently fails with "reading EventBridge Target
  # (...): empty result" even though the target was created (upstream bug
  # hashicorp/terraform-provider-aws#47687, unfixed as of provider 6.52.0).
  # Not creating the targets removes the race entirely.
  enable_spot_termination = false

  tags = local.tags
}

################################################################################
# Karpenter controller (Helm)
#
# Pinned to the system managed node group via nodeSelector so the controller is
# never scheduled onto a node it is itself responsible for provisioning.
################################################################################

resource "helm_release" "karpenter" {
  namespace           = "kube-system"
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.13.0"

  # wait=true so the release only completes once the bundled CRDs
  # (nodepools/ec2nodeclasses.karpenter.*) are Established AND the controller
  # is Ready. The null_resources below immediately `kubectl apply` NodePool /
  # EC2NodeClass CRs; without this they can race the CRD registration and fail
  # with "no matches for kind NodePool". The controller runs on the system MNG
  # (already up), so this settles in ~1 min.
  wait    = true
  timeout = 600

  values = [
    <<-EOT
    nodeSelector:
      workshop.io/node-role: system
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      # No interruptionQueue: native spot-termination handling is disabled on the
      # module (enable_spot_termination = false) because both NodePools are
      # on-demand only. With the queue gone, module.karpenter.queue_name is null;
      # leaving Karpenter's interruptionQueue unset disables interruption polling
      # (correct for an all-on-demand cluster).
    webhook:
      enabled: false
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter,
  ]
}

################################################################################
# General-purpose NodePool + EC2NodeClass
#
# On-demand only (reliability for a time-boxed workshop), amd64, AL2023, c/m/r
# families generation > 4. Subnets and the node security group are discovered
# by the karpenter.sh/discovery tag set in vpc.tf / base.tf.
#
# Applied with kubectl (not kubernetes_manifest) to avoid the provider's
# plan-time CRD lookup against a cluster that does not yet have Karpenter's
# CRDs installed. The destroy-time provisioner deletes the NodePool first so
# Karpenter drains and terminates its nodes before the cluster is torn down
# (otherwise the EC2 instances are orphaned and the VPC destroy hangs).
################################################################################

resource "null_resource" "karpenter_general_nodepool" {
  triggers = {
    cluster_name  = module.eks.cluster_name
    region        = local.region
    node_iam_role = module.karpenter.node_iam_role_name
    discovery_tag = local.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region}
      kubectl apply -f - <<'YAML'
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: default
      spec:
        amiFamily: AL2023
        amiSelectorTerms:
          - alias: al2023@latest
        role: ${self.triggers.node_iam_role}
        subnetSelectorTerms:
          - tags:
              karpenter.sh/discovery: ${self.triggers.discovery_tag}
        securityGroupSelectorTerms:
          - tags:
              karpenter.sh/discovery: ${self.triggers.discovery_tag}
        tags:
          karpenter.sh/discovery: ${self.triggers.discovery_tag}
      ---
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: general-purpose
      spec:
        template:
          spec:
            requirements:
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["on-demand"]
              - key: kubernetes.io/arch
                operator: In
                values: ["amd64"]
              - key: kubernetes.io/os
                operator: In
                values: ["linux"]
              - key: karpenter.k8s.aws/instance-category
                operator: In
                values: ["c", "m", "r"]
              - key: karpenter.k8s.aws/instance-generation
                operator: Gt
                values: ["4"]
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: default
            expireAfter: 720h
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmptyOrUnderutilized
          consolidateAfter: 30s
      YAML
    EOT
  }

  # Drain Karpenter-managed capacity before the cluster is destroyed.
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} || exit 0
      kubectl delete nodepool general-purpose --ignore-not-found --wait=true || true
      kubectl delete ec2nodeclass default --ignore-not-found --wait=true || true
    EOT
  }

  depends_on = [helm_release.karpenter]
}

################################################################################
# kata-containers + Firecracker NodePool (sandboxed workloads)
#
# A dedicated, tainted pool for hardware-isolated (microVM) pods. It relies on
# EC2 nested virtualization (Karpenter 1.13's cpuOptions.nestedVirtualization),
# so it is restricted to the 8i families (c8i/m8i/r8i — the only ones exposing
# /dev/kvm to the guest). The EC2NodeClass userData installs kata + Firecracker
# and registers a "kata-fc" containerd runtime; the RuntimeClass lets pods opt
# in with `runtimeClassName: kata-fc` (it carries the nodeSelector + toleration
# that target this pool).
#
# The manifests live in terraform/manifests/ as static files so the shell
# ${...} inside the install script is NOT touched by Terraform interpolation.
# Only the node IAM role and discovery tag are templated, via sed placeholders
# (__NODE_IAM_ROLE__ / __DISCOVERY_TAG__).
################################################################################

resource "null_resource" "karpenter_kata_fc" {
  triggers = {
    cluster_name  = module.eks.cluster_name
    region        = local.region
    node_iam_role = module.karpenter.node_iam_role_name
    discovery_tag = local.name
    manifest_dir  = "${path.module}/manifests"
    # Re-apply when any of the manifests change.
    ec2nodeclass_hash = filemd5("${path.module}/manifests/ec2nodeclass-kata-fc.yaml")
    nodepool_hash     = filemd5("${path.module}/manifests/nodepool-kata-fc.yaml")
    runtimeclass_hash = filemd5("${path.module}/manifests/runtimeclass-kata-fc.yaml")
  }

  provisioner "local-exec" {
    # bash (not the runner's default /bin/sh) for `set -o pipefail`.
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region}
      MANIFESTS="${self.triggers.manifest_dir}"
      sed -e "s|__NODE_IAM_ROLE__|${self.triggers.node_iam_role}|g" \
          -e "s|__DISCOVERY_TAG__|${self.triggers.discovery_tag}|g" \
          "$MANIFESTS/ec2nodeclass-kata-fc.yaml" | kubectl apply -f -
      kubectl apply -f "$MANIFESTS/nodepool-kata-fc.yaml"
      kubectl apply -f "$MANIFESTS/runtimeclass-kata-fc.yaml"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --name ${self.triggers.cluster_name} --region ${self.triggers.region} || exit 0
      kubectl delete runtimeclass kata-fc --ignore-not-found --wait=true || true
      kubectl delete nodepool kata-fc --ignore-not-found --wait=true || true
      kubectl delete ec2nodeclass kata-fc --ignore-not-found --wait=true || true
    EOT
  }

  depends_on = [helm_release.karpenter]
}
