provider "helm" {
  # In provider v3 `kubernetes` is an attribute, not a block, and `exec` is a
  # nested object rather than a nested block.
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    # Fetch a short-lived token per invocation instead of writing a kubeconfig.
    # Nothing long-lived is persisted to state or disk.
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

# IAM role the controller assumes via IRSA.
#
# IRSA rather than EKS Pod Identity: both work (Pod Identity has been supported
# since controller v2.7), but AWS's Load Balancer Controller documentation is
# written entirely against IRSA, and Pod Identity requires an out-of-band
# association resource that the Helm chart knows nothing about. IRSA keeps the
# whole binding declarative in one place.
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name = "${local.name}-alb-controller"

  # Attaches the upstream aws-load-balancer-controller policy. It is unchanged
  # between controller 2.x and 3.x, and is the same document published at
  # kubernetes-sigs/aws-load-balancer-controller/docs/install/iam_policy.json.
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # Must match the service account the chart creates, exactly.
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

resource "helm_release" "alb_controller" {
  name      = "aws-load-balancer-controller"
  namespace = "kube-system"

  # The HTTPS chart repository, deliberately not the OCI registry at
  # oci://public.ecr.aws/eks: helm_release against that registry fails with
  # "manifest does not contain minimum number of descriptors (2)"
  # (aws-load-balancer-controller issue #4682, still open).
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version

  # Roll back a failed install rather than leaving half a release behind.
  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 600

  # In provider v3 `set` is a list of objects, not a repeated block.
  set = [
    {
      name  = "clusterName"
      value = module.eks.cluster_name
    },

    # region and vpcId are optional in the chart and are normally discovered
    # through IMDS. They are set explicitly here because the node group runs
    # with http_put_response_hop_limit = 1, which deliberately prevents pods
    # from reaching the instance metadata service at all. Without these two
    # values the controller cannot determine where it is running.
    {
      name  = "region"
      value = var.region
    },
    {
      name  = "vpcId"
      value = module.vpc.vpc_id
    },

    # The chart would otherwise name the service account after the release,
    # which must match the IRSA trust condition above character for character.
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "aws-load-balancer-controller"
    },
    {
      # Dots inside the annotation key are escaped so Helm's parser treats the
      # key as a single map entry rather than a nested path.
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.alb_controller_irsa.arn
    },

    # The chart ships no resource requests. Unbounded control-plane components
    # are a scheduling hazard, and without a request the pod lands in
    # BestEffort and is first to be evicted under node pressure.
    {
      name  = "resources.requests.cpu"
      value = "100m"
    },
    {
      name  = "resources.requests.memory"
      value = "128Mi"
    },
    {
      name  = "resources.limits.memory"
      value = "256Mi"
    },
  ]

  # The chart's webhook must be reachable before any Ingress is admitted, and
  # its pods need somewhere to run.
  depends_on = [module.eks]
}
