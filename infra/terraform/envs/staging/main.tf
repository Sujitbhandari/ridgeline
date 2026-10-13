terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.80, < 6.0" }
  }
  # State is encrypted, versioned and locked. One state per environment keeps
  # the blast radius of a bad apply to that environment.
  backend "s3" {
    bucket       = "ridgeline-terraform-state-222222222222"
    key          = "staging/platform-cluster.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = ["222222222222"]
  default_tags {
    tags = {
      "ridgeline.dev/owner"       = "platform"
      "ridgeline.dev/cost-center" = "platform-engineering"
    }
  }
}

module "platform" {
  source = "../../modules/platform-cluster"

  environment        = "staging"
  vpc_cidr           = "10.40.0.0/16"
  single_nat_gateway = false
  node_min           = 3
  node_max           = 12
  catalog_path       = "${path.root}/../../../../access-requests/catalog.yaml"
}

output "workload_role_arns" {
  value = module.platform.workload_role_arns
}
