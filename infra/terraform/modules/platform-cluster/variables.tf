variable "environment" {
  description = "Environment name (dev, staging, prod). Prefixes every resource and IRSA role."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "kubernetes_version" {
  type    = string
  default = "1.32"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "az_count" {
  description = "Spread nodes across this many AZs. Three is the minimum for zone-failure tolerance with maxSkew=1."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "One NAT for the whole VPC (cheap, dev) vs one per AZ (resilient, staging/prod)."
  type        = bool
  default     = false
}

variable "endpoint_public_access" {
  type    = bool
  default = false
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach a public API endpoint, when enabled."
  type        = list(string)
  default     = []
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m6i.large", "m6a.large", "m7i.large"]
}

variable "node_min" {
  type    = number
  default = 3
}

variable "node_max" {
  type    = number
  default = 12
}

variable "catalog_path" {
  description = "Path to access-requests/catalog.yaml. Every workload listed there gets an IRSA role."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
