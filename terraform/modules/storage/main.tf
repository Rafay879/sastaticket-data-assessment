# Bronze/silver/gold S3 buckets, the Athena query-results bucket, and the
# DynamoDB table ingestion Lambdas use to track their watermarks.
# See DEPLOYMENT.md section 1.

variable "project_prefix" {
  type = string
}

variable "environment" {
  type = string
}

locals {
  bronze_bucket_name         = "${var.project_prefix}-${var.environment}-bronze"
  silver_bucket_name         = "${var.project_prefix}-${var.environment}-silver"
  gold_bucket_name           = "${var.project_prefix}-${var.environment}-gold"
  athena_results_bucket_name = "${var.project_prefix}-${var.environment}-athena-results"
  watermark_table_name       = "${var.project_prefix}-${var.environment}-pipeline-watermarks"
}

# -----------------------------------------------------------------------
# Bronze - raw, untransformed feeds landed by the ingestion Lambdas.
# -----------------------------------------------------------------------

resource "aws_s3_bucket" "bronze" {
  bucket = local.bronze_bucket_name
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  rule {
    apply_server_side_encryption_by_default {
      # swap to aws:kms with a customer-managed key in modules/security
      # once that module is added - deferred per README
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket                  = aws_s3_bucket.bronze.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.bronze.arn,
          "${aws_s3_bucket.bronze.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# Ingestion writes are small, frequent objects whose access pattern goes
# cold after the daily dbt run reads them - Intelligent-Tiering with the
# default tiers (Frequent/Infrequent Access, no Deep Archive) covers the
# whole bucket. See DEPLOYMENT.md section 1.
resource "aws_s3_bucket_intelligent_tiering_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id
  name   = "entire-bucket"
  status = "Enabled"

  # Archive tier only - Deep Archive intentionally omitted, since bronze
  # is still read (by the Glue crawler, and by dbt for backfills) often
  # enough that Deep Archive's multi-hour retrieval time isn't worth the
  # extra savings yet.
  tiering {
    access_tier = "ARCHIVE_ACCESS"
    days        = 90
  }
}

# -----------------------------------------------------------------------
# Silver - staged/intermediate dbt tables.
# -----------------------------------------------------------------------

resource "aws_s3_bucket" "silver" {
  bucket = local.silver_bucket_name
}

resource "aws_s3_bucket_versioning" "silver" {
  bucket = aws_s3_bucket.silver.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "silver" {
  bucket = aws_s3_bucket.silver.id
  rule {
    apply_server_side_encryption_by_default {
      # swap to aws:kms with a customer-managed key in modules/security
      # once that module is added - deferred per README
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "silver" {
  bucket                  = aws_s3_bucket.silver.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "silver" {
  bucket = aws_s3_bucket.silver.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.silver.arn,
          "${aws_s3_bucket.silver.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# Intelligent-Tiering not enabled while marts use full-rebuild
# materialization (see DEPLOYMENT.md section 6). Enable once incremental
# materialization is in place.

# -----------------------------------------------------------------------
# Gold - mart-layer output tables.
# -----------------------------------------------------------------------

resource "aws_s3_bucket" "gold" {
  bucket = local.gold_bucket_name
}

resource "aws_s3_bucket_versioning" "gold" {
  bucket = aws_s3_bucket.gold.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gold" {
  bucket = aws_s3_bucket.gold.id
  rule {
    apply_server_side_encryption_by_default {
      # swap to aws:kms with a customer-managed key in modules/security
      # once that module is added - deferred per README
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "gold" {
  bucket                  = aws_s3_bucket.gold.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "gold" {
  bucket = aws_s3_bucket.gold.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.gold.arn,
          "${aws_s3_bucket.gold.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# Intelligent-Tiering not enabled while marts use full-rebuild
# materialization (see DEPLOYMENT.md section 6). Enable once incremental
# materialization is in place.

# -----------------------------------------------------------------------
# Athena query-results bucket - not in the original storage spec, added
# because policies/fargate_dbt_task.json (AthenaResultsBucket statement)
# and modules/catalog's Athena workgroup both need somewhere for Athena to
# write result manifests + spilled data per query. Same security baseline
# as the three buckets above; a 30-day expiration replaces versioning/
# Intelligent-Tiering since this data is transient by design.
# -----------------------------------------------------------------------

resource "aws_s3_bucket" "athena_results" {
  bucket = local.athena_results_bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.athena_results.arn,
          "${aws_s3_bucket.athena_results.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-after-30-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

# -----------------------------------------------------------------------
# Watermarks - one row per source_name, tracking the last successfully
# ingested timestamp for each of the four ingestion Lambdas.
# -----------------------------------------------------------------------

resource "aws_dynamodb_table" "pipeline_watermarks" {
  name         = local.watermark_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "source_name"

  attribute {
    name = "source_name"
    type = "S"
  }

  # watermark loss = replaying a window of ingestion, which is idempotent
  # but wasteful - point-in-time recovery makes that an edge case rather
  # than a routine risk.
  point_in_time_recovery {
    enabled = true
  }
}

output "bronze_bucket_name" {
  value = aws_s3_bucket.bronze.bucket
}

output "silver_bucket_name" {
  value = aws_s3_bucket.silver.bucket
}

output "gold_bucket_name" {
  value = aws_s3_bucket.gold.bucket
}

output "athena_results_bucket_name" {
  value = aws_s3_bucket.athena_results.bucket
}

output "watermark_table_name" {
  value = aws_dynamodb_table.pipeline_watermarks.name
}

output "watermark_table_arn" {
  value = aws_dynamodb_table.pipeline_watermarks.arn
}
