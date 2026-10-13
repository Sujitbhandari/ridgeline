# One EKS cluster per environment, laid out for a high-compliance workload:
#   - private worker subnets across 3 AZs, private API endpoint by default
#   - secrets envelope-encrypted with a customer-managed KMS key
#   - control-plane audit logs and VPC flow logs on
#   - VPC CNI NetworkPolicy enforcement, so default-deny is actually enforced
#   - an IRSA role per catalog workload, fenced by a permissions boundary

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "ridgeline-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  catalog   = yamldecode(file(var.catalog_path))
  workloads = { for w in local.catalog.workloads : "${w.namespace}-${w.name}" => w }

  tags = merge(var.tags, {
    "ridgeline.dev/environment" = var.environment
    "ridgeline.dev/managed-by"  = "terraform"
  })
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.17"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway
  enable_dns_hostnames   = true

  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.admin_cidrs

  enable_cluster_creator_admin_permissions = true
  cluster_enabled_log_types                = ["api", "audit", "authenticator"]
  # The module creates a customer-managed KMS key and encrypts Secrets with it.
  create_kms_key = true
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    general = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"
      min_size       = var.node_min
      max_size       = var.node_max
      desired_size   = var.node_min
      labels         = { "ridgeline.dev/pool" = "general" }

      # IMDSv2 only, and pods can't reach the node's instance role
      # (hop limit 1): workloads must use their own IRSA role.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = 50
            volume_type = "gp3"
            encrypted   = true
          }
        }
      }
    }
  }

  tags = local.tags
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.52"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

# Defense in depth for self-service access. The boundary is the ceiling:
# an identity policy rendered by accessctl can only grant actions in this
# list (the same ones access-requests/catalog.yaml offers). Resource ARNs
# stay constrained by that identity policy. A workload role still cannot
# manage IAM, touch the org, or disable logging.
data "aws_iam_policy_document" "workload_boundary" {
  statement {
    sid    = "CatalogActionsOnly"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem", "dynamodb:Query", "dynamodb:BatchGetItem", "dynamodb:PutItem",
      "sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes",
      "s3:GetObject", "s3:PutObject",
      "kms:Decrypt", "kms:GenerateDataKey",
      "secretsmanager:GetSecretValue",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "NeverFromAWorkload"
    effect    = "Deny"
    actions   = ["iam:*", "organizations:*", "cloudtrail:*", "kms:ScheduleKeyDeletion", "kms:PutKeyPolicy", "s3:PutBucketPolicy", "s3:DeleteBucket"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "workload_boundary" {
  name        = "${local.name}-workload-boundary"
  description = "Permissions boundary for every Ridgeline workload IRSA role"
  policy      = data.aws_iam_policy_document.workload_boundary.json
  tags        = local.tags
}

# Roles start with zero permissions. Merged AccessRequests attach least-
# privilege policies to them (infra/terraform/access).
module "workload_irsa" {
  source   = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version  = "~> 5.52"
  for_each = local.workloads

  role_name                     = "${var.environment}-${each.value.namespace}-${each.value.name}"
  role_permissions_boundary_arn = aws_iam_policy.workload_boundary.arn
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${each.value.namespace}:${each.value.name}"]
    }
  }
  tags = merge(local.tags, { "ridgeline.dev/team" = each.value.team })
}
