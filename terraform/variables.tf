variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Name prefix applied to every resource."
  type        = string
  default     = "hivemind-greeter"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, 3-31 characters, starting with a letter."
  }
}

variable "environment" {
  description = "Environment name, used for tagging."
  type        = string
  default     = "dev"
}

variable "additional_tags" {
  description = "Extra tags merged into the default tag set."
  type        = map(string)
  default     = {}
}

# ---- networking --------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be large enough to carve az_count public plus az_count private /20s."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread across. Three is the minimum for a meaningful HA story."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "enable_flow_logs" {
  description = <<-EOT
    Record VPC Flow Logs to CloudWatch.

    Limited to REJECT traffic, which keeps ingestion cost near zero at this
    volume while still capturing the signal that matters: policy denials and
    probing. Switch to ALL for a real investigation.
  EOT
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = <<-EOT
    Route all private egress through one NAT gateway instead of one per AZ.

    Defaults to false so the deployment is genuinely highly available: a
    per-AZ NAT means losing an AZ does not sever egress for the survivors.
    Setting this to true saves roughly USD 65/month per removed gateway and is
    a reasonable choice for a short-lived review environment, at the cost of
    making that single AZ a dependency for all outbound traffic.
  EOT
  type        = bool
  default     = false
}

# ---- cluster -----------------------------------------------------------------

variable "kubernetes_version" {
  description = <<-EOT
    EKS control plane version. Must be in STANDARD support.

    This matters financially, not just operationally: a cluster on a version in
    extended support is billed at USD 0.60/cluster-hour instead of 0.10 — an
    extra ~USD 365/month for running something merely out of date.

    Standard support as of 2026-09-20 (verified against AWS docs):
      1.36  end of standard support 2027-08-02   <- default
      1.35  end of standard support 2027-03-27
      1.34  end of standard support 2026-12-02   (~2 months left, avoid)
    Already in extended support, do not use: 1.33, 1.32, 1.31.

    1.36 is chosen over the more conservative N-1 because its breaking changes
    are all migration hazards rather than greenfield ones (gitRepo volume
    removal, IPVS kube-proxy removal, containerd 2.0+, stricter CIDR
    validation) and a new AL2023 cluster satisfies every one of them. It also
    buys ~11 months of runway instead of ~6.

    Re-verify before applying, since this list ages:
      aws eks describe-cluster-versions --region <region>
  EOT
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDRs permitted to reach the public Kubernetes API endpoint.

    Defaults to 0.0.0.0/0 so the CI pipeline and a reviewer on an unknown
    network can both reach it. Narrow this to known egress ranges for anything
    beyond a review environment; see README "Tradeoffs".
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Instance types for the managed node group, in order of preference."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_group_min_size" {
  description = "Minimum nodes in the managed node group."
  type        = number
  default     = 3
}

variable "node_group_max_size" {
  description = "Maximum nodes in the managed node group."
  type        = number
  default     = 6
}

variable "node_group_desired_size" {
  description = "Initial node count. Defaults to one per AZ."
  type        = number
  default     = 3
}

variable "cluster_admin_principal_arns" {
  description = <<-EOT
    Additional IAM principal ARNs granted cluster-admin via EKS access entries.

    The identity running `terraform apply` is admitted automatically. Add the
    CI deploy role here so the pipeline can reach the API server.
  EOT
  type        = list(string)
  default     = []
}

# ---- application -------------------------------------------------------------

variable "enable_enhanced_scanning" {
  description = <<-EOT
    Switch the registry to ECR Enhanced scanning (Amazon Inspector).

    Off by default because it is a registry-wide, billable change rather than a
    per-repository one — roughly USD 0.09 per image per month plus rescans.

    Turn it on for any real deployment of this service. BASIC scanning cannot
    read a scratch image at all (no OS, no package manager), so without this
    the repository's scan_on_push produces nothing.
  EOT
  type        = bool
  default     = false
}

variable "ecr_image_retention_count" {
  description = "Number of tagged images to retain in ECR before lifecycle expiry."
  type        = number
  default     = 20
}

# ---- CI/CD federation -----------------------------------------------------------

variable "github_repository" {
  description = <<-EOT
    GitHub repository in "owner/name" form permitted to assume the deploy role
    through OIDC. Leave empty to skip creating any CI/CD federation at all.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.github_repository == "" || can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be empty or in owner/name form."
  }
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the GitHub OIDC provider in this account.

    An account can hold only one provider per issuer URL, so set this to false
    if another stack already created it; the existing one is looked up instead.
  EOT
  type        = bool
  default     = true
}

variable "github_deploy_subjects" {
  description = <<-EOT
    OIDC subject patterns allowed to assume the deploy role, appended to
    "repo:<owner>/<name>:".

    This is the only thing standing between this role and every repository on
    GitHub, so keep it narrow. "*" would permit any branch, any pull request
    and any fork.
  EOT
  type        = list(string)
  default = [
    "ref:refs/heads/main",
    "environment:production",
  ]

  validation {
    condition     = length(var.github_deploy_subjects) > 0
    error_message = "github_deploy_subjects must not be empty; an unscoped trust policy is assumable by any GitHub repository."
  }

  validation {
    condition     = !contains(var.github_deploy_subjects, "*")
    error_message = "github_deploy_subjects must not contain a bare '*'."
  }
}

# ---- load balancer controller --------------------------------------------------

variable "alb_controller_chart_version" {
  description = <<-EOT
    Version of the aws-load-balancer-controller Helm chart.

    Pinned deliberately: an unpinned chart makes the cluster's ingress layer
    change underneath you on an unrelated apply.

    Beware the version scheme. The chart skipped 2.x entirely, going 1.17.1 ->
    3.0.0 so that chart and controller versions finally align (chart 1.17.1 was
    controller v2.17.1; chart 3.5.0 is controller v3.5.0). A "1.x" chart is
    therefore old, not stable.

    Do not drop below 3.3.0. Charts 3.0.0-3.2.2 shipped broken Gateway API CRD
    auto-detection and crash-loop on clusters without those CRDs installed
    (upstream issues #4684, #4674, #4712).
  EOT
  type        = string
  default     = "3.5.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.alb_controller_chart_version))
    error_message = "alb_controller_chart_version must be an exact semantic version, e.g. 3.5.0."
  }
}
