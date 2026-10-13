# Root module for self-service IAM grants. CI copies the accessctl output for
# one environment next to this file and plans/applies it:
#
#   cp access-requests/rendered/$ENV/iam/*.tf.json infra/terraform/access/
#   terraform -chdir=infra/terraform/access init -backend-config=backend-$ENV.hcl
#   terraform -chdir=infra/terraform/access plan
#
# When a request expires and its file is deleted, the next apply removes the
# policy. Nothing has to remember to clean up.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.80, < 6.0" }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}
