# The four ingestion Lambdas (see ../../lambdas/*/handler.py), the shared
# IAM role they run under, their log groups, and the Secrets Manager
# placeholders for upstream API credentials. See DEPLOYMENT.md section 1.

terraform {
  required_providers {
    archive = {
      source = "hashicorp/archive"
    }
  }
}

variable "project_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "watermark_table_name" {
  type = string
}

variable "watermark_table_arn" {
  type = string
}

variable "bronze_bucket_name" {
  type = string
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix       = "${var.project_prefix}-${var.environment}"
  bronze_bucket_arn = "arn:aws:s3:::${var.bronze_bucket_name}"

  # GDS and LCC are third-party APIs that need credentials. Payments and
  # reference-data sync authenticate a different way (internal
  # service-to-service auth, out of scope here) - no secret for them yet.
  ingestion_sources = {
    gds = {
      source_dir = "${path.module}/../../lambdas/gds_ingestion"
      secret_key = "gds_api"
    }
    lcc = {
      source_dir = "${path.module}/../../lambdas/lcc_ingestion"
      secret_key = "lcc_api"
    }
    payments = {
      source_dir = "${path.module}/../../lambdas/payments_ingestion"
      secret_key = null
    }
    reference = {
      source_dir = "${path.module}/../../lambdas/reference_sync"
      secret_key = null
    }
  }
}

# -----------------------------------------------------------------------
# Secrets - placeholders only. The secret VALUE (the actual API key/
# token) is set out-of-band (console, or a separate access-controlled
# process) rather than in Terraform, since state is readable by anyone
# with plan/apply access to this config.
# -----------------------------------------------------------------------

resource "aws_secretsmanager_secret" "gds_api" {
  name = "${var.project_prefix}/ingestion/gds_api"
}

resource "aws_secretsmanager_secret" "lcc_api" {
  name = "${var.project_prefix}/ingestion/lcc_api"
}

locals {
  secret_arns = {
    gds_api = aws_secretsmanager_secret.gds_api.arn
    lcc_api = aws_secretsmanager_secret.lcc_api.arn
  }
}

# -----------------------------------------------------------------------
# Shared IAM role - all four functions have identical permissions (read
# their own watermark, write bronze, read their own secret, write logs),
# so one role covers all four rather than four near-identical roles.
# -----------------------------------------------------------------------

resource "aws_iam_role" "lambda_ingestion" {
  name = "${local.name_prefix}-lambda-ingestion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "lambda_ingestion" {
  name = "${local.name_prefix}-lambda-ingestion"

  # See ../../policies/lambda_ingestion.json for the full statement-by-
  # statement rationale (ReadWatermark, PutBronzeObjects,
  # GetIngestionSecrets, WriteLogs).
  policy = templatefile("${path.module}/../../policies/lambda_ingestion.json", {
    watermark_table_arn = var.watermark_table_arn
    bronze_bucket_arn   = local.bronze_bucket_arn
    region              = var.aws_region
    account_id          = data.aws_caller_identity.current.account_id
    project_prefix      = var.project_prefix
    environment         = var.environment
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ingestion" {
  role       = aws_iam_role.lambda_ingestion.name
  policy_arn = aws_iam_policy.lambda_ingestion.arn
}

# -----------------------------------------------------------------------
# Log groups - created explicitly (rather than letting Lambda create them
# implicitly on first invoke) so retention is set from day one.
# -----------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ingestion" {
  for_each = local.ingestion_sources

  name              = "/aws/lambda/${local.name_prefix}-${each.key}-ingestion"
  retention_in_days = 30
}

# -----------------------------------------------------------------------
# Packaging - zips each lambdas/<source>/ folder as-is (business logic is
# still a stub - see each handler.py's docstring).
# -----------------------------------------------------------------------

data "archive_file" "ingestion" {
  for_each = local.ingestion_sources

  type        = "zip"
  source_dir  = each.value.source_dir
  output_path = "${path.module}/.build/${each.key}_ingestion.zip"
}

resource "aws_lambda_function" "ingestion" {
  for_each = local.ingestion_sources

  function_name = "${local.name_prefix}-${each.key}-ingestion"
  role          = aws_iam_role.lambda_ingestion.arn

  filename         = data.archive_file.ingestion[each.key].output_path
  source_code_hash = data.archive_file.ingestion[each.key].output_base64sha256

  runtime     = "python3.11"
  handler     = "handler.lambda_handler"
  timeout     = 300
  memory_size = 512

  environment {
    variables = merge(
      {
        WATERMARK_TABLE = var.watermark_table_name
        BRONZE_BUCKET   = var.bronze_bucket_name
      },
      each.value.secret_key == null ? {} : {
        SECRET_ARN = local.secret_arns[each.value.secret_key]
      }
    )
  }

  depends_on = [aws_cloudwatch_log_group.ingestion]
}

output "lambda_function_arns" {
  value = { for k, v in aws_lambda_function.ingestion : k => v.arn }
}

output "ingestion_role_arn" {
  value = aws_iam_role.lambda_ingestion.arn
}
