# Federated deploy role for GitHub Actions.
#
# The pipeline authenticates by exchanging a short-lived GitHub OIDC token for
# AWS credentials, so no long-lived access key is ever minted, stored as a
# repository secret, or rotated by hand.
#
# Entirely optional: leave var.github_repository empty and none of this is
# created.

locals {
  github_oidc_enabled = var.github_repository != ""

  github_oidc_arn = local.github_oidc_enabled ? (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  ) : null

  github_owner = local.github_oidc_enabled ? split("/", var.github_repository)[0] : ""
  github_name  = local.github_oidc_enabled ? split("/", var.github_repository)[1] : ""

  # GitHub issues one of two subject formats, and which one you get is not
  # something the workflow controls:
  #
  #   classic  repo:owner/name:environment:production
  #   ID-bound repo:owner@1234567/name@7654321:environment:production
  #
  # The second embeds the numeric owner and repository IDs so that renaming
  # either does not silently transfer trust. Every example in the AWS and
  # GitHub docs shows the classic form, so a policy written from them fails
  # closed against an account issuing the ID-bound one — with a bare
  # "Not authorized to perform sts:AssumeRoleWithWebIdentity" and nothing
  # pointing at the subject.
  #
  # Both forms are allowed. The wildcard is narrower than it looks: GitHub
  # permits neither "@" in usernames nor in repository names, so "owner@*" can
  # only ever match that owner followed by its own numeric id.
  github_subjects = local.github_oidc_enabled ? flatten([
    for subject in var.github_deploy_subjects : [
      "repo:${var.github_repository}:${subject}",
      "repo:${local.github_owner}@*/${local.github_name}@*:${subject}",
    ]
  ]) : []
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.github_oidc_enabled && var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # thumbprint_list is deliberately omitted. It is optional in AWS provider v6,
  # and IAM verifies GitHub's certificate chain against its own trust store for
  # this well-known provider. Pinning a thumbprint here would only create a
  # breakage when GitHub rotates its CA.

  tags = local.tags
}

# An AWS account may hold only one OIDC provider per URL. If one already exists
# — likely, if any other repository in the account deploys this way — set
# create_github_oidc_provider = false and it is looked up instead.
data "aws_iam_openid_connect_provider" "github" {
  count = local.github_oidc_enabled && !var.create_github_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_assume" {
  count = local.github_oidc_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The load-bearing condition. Without a `sub` constraint the trust policy
    # would accept a token from ANY repository on GitHub, letting any user on
    # the platform assume this role. Scope it as tightly as the workflow allows.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.github_subjects
    }

    # Belt and braces: `repository` is an exact string with no ID suffix in
    # either subject format, so this holds the scope even if the sub patterns
    # above were ever loosened.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository"
      values   = [var.github_repository]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  count = local.github_oidc_enabled ? 1 : 0

  name               = "${local.name}-github-deploy"
  description        = "Assumed by GitHub Actions to push images and deploy to ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.github_assume[0].json

  # An upper bound on the blast radius of any policy attached to this role.
  max_session_duration = 3600

  tags = local.tags
}

data "aws_iam_policy_document" "github_deploy" {
  count = local.github_oidc_enabled ? 1 : 0

  # GetAuthorizationToken is account-wide by API design; it cannot be scoped to
  # a repository. It only returns a token, which is then constrained by the
  # repository-scoped statement below.
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPullThisRepositoryOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.greeter.arn]
  }

  # Enough to run `aws eks update-kubeconfig`. What the role may then DO inside
  # the cluster is governed by the access entry below, not by IAM.
  statement {
    sid       = "EKSDescribeThisClusterOnly"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  count = local.github_oidc_enabled ? 1 : 0

  name   = "${local.name}-github-deploy"
  role   = aws_iam_role.github_deploy[0].id
  policy = data.aws_iam_policy_document.github_deploy[0].json
}

# Cluster-side authorisation, kept separate from IAM.
resource "aws_eks_access_entry" "github_deploy" {
  count = local.github_oidc_enabled ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_deploy[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_deploy" {
  count = local.github_oidc_enabled ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_deploy[0].arn

  # Edit rather than Admin, and namespace-scoped rather than cluster-scoped:
  # the pipeline can manage workloads in its own namespace and nothing else.
  # This is only possible because the namespace itself is created by Terraform;
  # see namespace.tf.
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [kubernetes_namespace_v1.app.metadata[0].name]
  }

  depends_on = [aws_eks_access_entry.github_deploy]
}
