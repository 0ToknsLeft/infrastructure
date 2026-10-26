terraform {
  required_version = ">= 1.16.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }

  # The bucket is created per account by `make setup` and passed to init
  backend "s3" {
    key          = "infra.tfstate"
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region to deploy resources into"
  type        = string
  default     = "eu-central-1"
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "aws_region" {
  description = "AWS region the resources are deployed into"
  value       = var.aws_region
}
