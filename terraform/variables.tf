variable "cluster_version" {
  description = "EKS cluster version."
  type        = string
  default     = "1.36"
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach the internet-facing ALBs (the alb.ingress.kubernetes.io/inbound-cidrs annotation). Required; pass [\"0.0.0.0/0\"] only to intentionally allow all."
  type        = list(string)
  # No default — required input so 0.0.0.0/0 is never a silent default.
}

variable "adot_addon_version" {
  description = "Version of the ADOT (AWS Distro for OpenTelemetry) EKS managed addon. Leave null to use the default version for the cluster's Kubernetes version."
  type        = string
  default     = null
}
