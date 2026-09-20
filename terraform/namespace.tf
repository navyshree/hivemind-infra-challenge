provider "kubernetes" {
  # Note the shape differs from the helm provider above: here the connection
  # fields are top-level attributes and `exec` is a nested block, whereas the
  # helm v3 provider takes a single `kubernetes = { ... }` attribute with `exec`
  # as a nested object. They are not interchangeable.
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

# The namespace is provisioned here rather than by Kustomize on purpose.
#
# A namespace is cluster-scoped, so anything that creates it needs cluster-scoped
# permission. Leaving it to the deploy pipeline would force the CD role up to
# cluster-wide edit rights just to run `kubectl apply`. Creating it as
# infrastructure lets the CD role stay scoped to this one namespace — see the
# access entry in github_oidc.tf.
resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = local.name

    labels = {
      "app.kubernetes.io/name" = local.name

      # Opts the namespace into ALB pod readiness gates. The Load Balancer
      # Controller then holds a pod "not ready" until its target has actually
      # passed health checks in the target group, so a rolling update cannot
      # retire old pods before the ALB is routing to the new ones.
      "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled"

      # Enforce the restricted Pod Security Standard: workloads asking for
      # privilege they should not have are rejected at admission.
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/warn"            = "restricted"
    }
  }

  # The ALB controller must be running before workloads land here, or the
  # readiness-gate webhook is not yet registered to inject the gate.
  depends_on = [helm_release.alb_controller]
}
