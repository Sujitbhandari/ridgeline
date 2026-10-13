output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "workload_role_arns" {
  description = "IRSA role per workload; the platform-service chart derives the same ARN from aws.accountId."
  value       = { for k, m in module.workload_irsa : k => m.iam_role_arn }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
