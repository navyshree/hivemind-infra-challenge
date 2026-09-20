output "region" {
  description = "AWS region the stack is deployed in."
  value       = var.region
}

output "account_id" {
  description = "AWS account ID the stack is deployed in."
  value       = data.aws_caller_identity.current.account_id
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_oidc_provider_arn" {
  description = "IRSA OIDC provider ARN, for granting IAM roles to service accounts."
  value       = module.eks.oidc_provider_arn
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs hosting the worker nodes."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs hosting the internet-facing load balancers."
  value       = module.vpc.public_subnets
}

output "availability_zones" {
  description = "Availability zones the cluster spans."
  value       = local.azs
}

output "ecr_repository_url" {
  description = "ECR repository URL for the greeter image."
  value       = aws_ecr_repository.greeter.repository_url
}

output "hello_tag" {
  description = "HELLO_TAG value Terraform was applied with."
  value       = var.hello_tag
}

output "github_deploy_role_arn" {
  description = "IAM role GitHub Actions assumes via OIDC. Null when github_repository is unset."
  value       = local.github_oidc_enabled ? aws_iam_role.github_deploy[0].arn : null
}

output "github_actions_variables" {
  description = <<-EOT
    Repository variables the CD workflow expects. Set them under
    Settings > Secrets and variables > Actions > Variables. They are
    configuration, not secrets — the OIDC trust policy is what grants access.
  EOT
  value = local.github_oidc_enabled ? {
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.github_deploy[0].arn
    AWS_REGION          = var.region
    ECR_REPOSITORY      = aws_ecr_repository.greeter.name
    EKS_CLUSTER_NAME    = module.eks.cluster_name
  } : null
}

output "namespace" {
  description = "Kubernetes namespace the workload is deployed into."
  value       = kubernetes_namespace_v1.app.metadata[0].name
}

output "configure_kubectl" {
  description = "Command to point kubectl at this cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "get_service_url" {
  description = "Command that prints the public URL once the ingress has provisioned its ALB."
  value       = "kubectl -n ${local.name} get ingress ${local.name} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
