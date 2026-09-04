terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
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

  project_prefix       = var.project_prefix
  environment          = var.environment
  aws_region           = var.aws_region
  watermark_table_name = module.storage.watermark_table_name
  watermark_table_arn  = module.storage.watermark_table_arn
  bronze_bucket_name   = module.storage.bronze_bucket_name
}

module "catalog" {
  source = "./modules/catalog"

  project_prefix             = var.project_prefix
  environment                = var.environment
  bronze_bucket_name         = module.storage.bronze_bucket_name
  athena_results_bucket_name = module.storage.athena_results_bucket_name
}

module "compute" {
  source = "./modules/compute"

  project_prefix             = var.project_prefix
  environment                = var.environment
  aws_region                 = var.aws_region
  bronze_bucket_name         = module.storage.bronze_bucket_name
  silver_bucket_name         = module.storage.silver_bucket_name
  gold_bucket_name           = module.storage.gold_bucket_name
  athena_results_bucket_name = module.storage.athena_results_bucket_name
  glue_database_name         = module.catalog.glue_database_name
  athena_workgroup_name      = module.catalog.athena_workgroup_name
}

module "monitoring" {
  source = "./modules/monitoring"

  project_prefix = var.project_prefix
  environment    = var.environment
  aws_region     = var.aws_region
  alerts_email   = var.alerts_email
}

module "orchestration" {
  source = "./modules/orchestration"

  project_prefix             = var.project_prefix
  environment                = var.environment
  aws_region                 = var.aws_region
  schedule_expression        = var.schedule_expression
  lambda_function_arns       = module.ingestion.lambda_function_arns
  cluster_arn                = module.compute.cluster_arn
  task_definition_arn        = module.compute.task_definition_arn
  fargate_task_role_arn      = module.compute.task_role_arn
  fargate_execution_role_arn = module.compute.execution_role_arn
  glue_crawler_name          = module.catalog.glue_crawler_name
  sns_topic_arn              = module.monitoring.sns_topic_arn
}
