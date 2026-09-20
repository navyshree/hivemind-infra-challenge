module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # The control plane ENIs sit in the private subnets; the managed public
  # endpoint below is what operators and CI actually talk to.
  control_plane_subnet_ids = module.vpc.private_subnets

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Control plane logs to CloudWatch. "api" and "authenticator" are the two
  # that matter when debugging a failed deploy or an access-denied.
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 30

  # IRSA: gives the cluster an OIDC provider so service accounts can assume IAM
  # roles without node-level credentials.
  enable_irsa = true

  # Access entries only, no aws-auth ConfigMap.
  #
  # Set explicitly on purpose: when a cluster is created through the SDK — which
  # is what Terraform uses — the EKS API defaults this to CONFIG_MAP, not to the
  # console's API_AND_CONFIG_MAP. Leaving it unset silently lands you on the
  # ConfigMap path. AWS recommends access entries (the ConfigMap is not formally
  # deprecated, but it is no longer the recommended mechanism), and they are
  # declarative and recoverable where a malformed ConfigMap can lock everyone
  # out of the cluster.
  #
  # Note the transition is one-way: CONFIG_MAP -> API_AND_CONFIG_MAP -> API,
  # never backwards. Starting at API avoids ever needing to migrate.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for idx, arn in var.cluster_admin_principal_arns : "admin-${idx}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  addons = {
    coredns                = {}
    kube-proxy             = {}
    eks-pod-identity-agent = {}

    vpc-cni = {
      # The CNI runs before nodes are ready, so it must not wait on them.
      before_compute = true
    }

    # Supplies the resource metrics API. Without it the HorizontalPodAutoscaler
    # reports <unknown>/70% and never scales. Available as a managed add-on, so
    # there is no reason to carry a Helm release for it — though note it is a
    # "community" add-on: AWS manages its lifecycle, not the software itself.
    metrics-server = {}

    # Detects kernel, networking and storage faults on nodes and feeds EKS node
    # auto-repair.
    eks-node-monitoring-agent = {}
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      # Spread across every private subnet so the group survives an AZ loss.
      subnet_ids = module.vpc.private_subnets

      # AL2023 is the current default host OS; AL2 is end of life.
      ami_type = "AL2023_x86_64_STANDARD"

      # Root volume: encrypted, gp3, sized for images plus ephemeral logs.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # IMDSv2 required, hop limit 1: stops a compromised pod from reaching
      # the instance metadata service to steal the node role's credentials.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      labels = {
        workload = "general"
      }

      tags = local.tags
    }
  }

  tags = local.tags
}
