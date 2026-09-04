# The Glue Data Catalog database gold-layer (and bronze-layer) tables
# register into, the crawler that populates it from bronze, and the
# Athena workgroup dbt-athena queries through. See DEPLOYMENT.md section 3.

variable "project_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "bronze_bucket_name" {
  type = string
}

variable "athena_results_bucket_name" {
  type = string
}

locals {
  name_prefix        = "${var.project_prefix}-${var.environment}"
  glue_database_name = "${var.project_prefix}_${var.environment}"
  bronze_bucket_arn  = "arn:aws:s3:::${var.bronze_bucket_name}"
}

resource "aws_glue_catalog_database" "this" {
  name = local.glue_database_name
}

# -----------------------------------------------------------------------
# Crawler role
# -----------------------------------------------------------------------

resource "aws_iam_role" "glue_crawler" {
  name = "${local.name_prefix}-glue-crawler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "glue.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# AWS-managed policy chosen for the standard Glue service actions (crawler
# state management, its own CloudWatch Logs); the inline policy below
# scopes S3 access to the bronze bucket only, rather than the managed
# policy's default of any bucket named aws-glue-*.
resource "aws_iam_role_policy_attachment" "glue_crawler_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_crawler_bronze_read" {
  name = "${local.name_prefix}-glue-crawler-bronze-read"
  role = aws_iam_role.glue_crawler.id

  # See ../../policies/glue_crawler.json for the full rationale.
  policy = templatefile("${path.module}/../../policies/glue_crawler.json", {
    bronze_bucket_arn = local.bronze_bucket_arn
  })
}

# -----------------------------------------------------------------------
# Crawler - only bronze needs crawling. Silver/gold are Iceberg tables
# written directly by dbt-athena with known schemas, so their catalog
# entries are created/updated by dbt itself (see
# policies/fargate_dbt_task.json GlueCatalogAccess), not by a crawler.
# -----------------------------------------------------------------------

resource "aws_glue_crawler" "bronze" {
  name          = "${local.name_prefix}-bronze-crawler"
  database_name = aws_glue_catalog_database.this.name
  role          = aws_iam_role.glue_crawler.arn

  s3_target {
    path = "s3://${var.bronze_bucket_name}/"
  }

  # LOG (not UPDATE_IN_DATABASE) - catches an unexpected upstream schema
  # change as a log signal to investigate, rather than silently altering
  # the catalog underneath dbt's source() definitions.
  schema_change_policy {
    update_behavior = "LOG"
    delete_behavior = "LOG"
  }

  # No `schedule` block: the crawler is invoked on-demand by the Step
  # Functions state machine's RunCrawler state, only when new records
  # actually landed. A Glue-native schedule would run it regardless,
  # defeating the point of the state machine's Choice-state skip.
}

# -----------------------------------------------------------------------
# Athena workgroup - the "compute" dbt-athena issues queries through.
# -----------------------------------------------------------------------

resource "aws_athena_workgroup" "dbt" {
  name = "${local.name_prefix}-dbt"

  configuration {
    # Prevents individual queries from redirecting output elsewhere -
    # every query in this workgroup writes results to the same bucket,
    # regardless of what the client/driver requests.
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${var.athena_results_bucket_name}/"
    }
  }
}

output "glue_database_name" {
  value = aws_glue_catalog_database.this.name
}

output "glue_crawler_name" {
  value = aws_glue_crawler.bronze.name
}

output "athena_workgroup_name" {
  value = aws_athena_workgroup.dbt.name
}
