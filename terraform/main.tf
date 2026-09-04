terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Set `bucket` to the tfstate bootstrap bucket once created (see
  # README.md "Bootstrap"). DynamoDB table for state locking should be
  # named sastaticket-terraform-locks.
  backend "s3" {
    bucket         = ""
    key            = "sastaticket/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "sastaticket-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

module "storage" {
  source = "./modules/storage"

  project_prefix = var.project_prefix
  environment    = var.environment
}

module "ingestion" {
  source = "./modules/ingestion"

  project_prefix = var.project_prefix
  environment    = var.environment
}

module "compute" {
  source = "./modules/compute"

  project_prefix = var.project_prefix
  environment    = var.environment
}

module "orchestration" {
  source = "./modules/orchestration"

  project_prefix = var.project_prefix
  environment    = var.environment
}

module "catalog" {
  source = "./modules/catalog"

  project_prefix = var.project_prefix
  environment    = var.environment
}

module "monitoring" {
  source = "./modules/monitoring"

  project_prefix = var.project_prefix
  environment    = var.environment
}
