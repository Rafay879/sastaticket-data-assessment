# The ECR repo dbt images are pushed to, the ECS cluster + Fargate task
# definition that runs `dbt build`, and the two IAM roles a Fargate task
# needs (execution role: pull the image, write container logs; task role:
# what the running container itself can do in AWS). See DEPLOYMENT.md
# section 2.

variable "project_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "bronze_bucket_name" {
  type = string
}

variable "silver_bucket_name" {
  type = string
}

variable "gold_bucket_name" {
  type = string
}

variable "athena_results_bucket_name" {
  type = string
}

variable "glue_database_name" {
  type = string
}

variable "athena_workgroup_name" {
  type = string
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_prefix}-${var.environment}"

  bronze_bucket_arn         = "arn:aws:s3:::${var.bronze_bucket_name}"
  silver_bucket_arn         = "arn:aws:s3:::${var.silver_bucket_name}"
  gold_bucket_arn           = "arn:aws:s3:::${var.gold_bucket_name}"
  athena_results_bucket_arn = "arn:aws:s3:::${var.athena_results_bucket_name}"
}

# -----------------------------------------------------------------------
# Image repository
# -----------------------------------------------------------------------

resource "aws_ecr_repository" "dbt" {
  name = "${local.name_prefix}-dbt"

  # immutable tags prevent :latest ambiguity in production runs - deploys
  # reference a specific SHA-tagged image
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    # AWS-managed key (aws/ecr); see terraform/README.md "What's NOT here"
    # for why a customer-managed key is deferred.
  }
}

# -----------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------

resource "aws_ecs_cluster" "orchestrator" {
  name = "${local.name_prefix}-orchestrator"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_cloudwatch_log_group" "dbt" {
  name              = "/ecs/${local.name_prefix}-dbt"
  retention_in_days = 30
}

# -----------------------------------------------------------------------
# Execution role - pulls the image from ECR, writes container stdout/
# stderr to CloudWatch Logs. Distinct from the task role below: this is
# what ECS itself does to start the container, not what the container's
# own code can do once running.
# -----------------------------------------------------------------------

resource "aws_iam_role" "fargate_task_execution" {
  name = "${local.name_prefix}-fargate-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# The AWS-managed AmazonECSTaskExecutionRolePolicy is already a
# well-scoped, standard policy for exactly this job (ECR pull + Logs
# write) - writing a custom equivalent would just add maintenance burden
# without a security gain.
resource "aws_iam_role_policy_attachment" "fargate_task_execution" {
  role       = aws_iam_role.fargate_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# -----------------------------------------------------------------------
# Task role - what the dbt container itself can do: read bronze, read/
# write silver+gold, manage Glue table metadata, run Athena queries.
# -----------------------------------------------------------------------

resource "aws_iam_role" "fargate_dbt_task" {
  name = "${local.name_prefix}-fargate-dbt-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "fargate_dbt_task" {
  name = "${local.name_prefix}-fargate-dbt-task"

  # See ../../policies/fargate_dbt_task.json for the full statement-by-
  # statement rationale (ReadBronze, ReadWriteSilverGold,
  # GlueCatalogAccess, AthenaExecute, AthenaWorkgroupRead,
  # AthenaResultsBucket).
  policy = templatefile("${path.module}/../../policies/fargate_dbt_task.json", {
    bronze_bucket_arn         = local.bronze_bucket_arn
    silver_bucket_arn         = local.silver_bucket_arn
    gold_bucket_arn           = local.gold_bucket_arn
    athena_results_bucket_arn = local.athena_results_bucket_arn
    region                    = var.aws_region
    account_id                = data.aws_caller_identity.current.account_id
    glue_database_name        = var.glue_database_name
    athena_workgroup_name     = var.athena_workgroup_name
  })
}

resource "aws_iam_role_policy_attachment" "fargate_dbt_task" {
  role       = aws_iam_role.fargate_dbt_task.name
  policy_arn = aws_iam_policy.fargate_dbt_task.arn
}

# -----------------------------------------------------------------------
# Task definition
# -----------------------------------------------------------------------

resource "aws_ecs_task_definition" "dbt" {
  family                   = "${local.name_prefix}-dbt"
  cpu                      = "512"
  memory                   = "1024"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.fargate_task_execution.arn
  task_role_arn            = aws_iam_role.fargate_dbt_task.arn

  container_definitions = jsonencode([
    {
      name = "dbt"
      # in production this is pinned to a specific tag/SHA; :latest here
      # is a placeholder
      image     = "${aws_ecr_repository.dbt.repository_url}:latest"
      essential = true
      command   = ["dbt", "build"]

      environment = [
        { name = "DBT_TARGET", value = "prod" },
        { name = "DBT_PROFILES_DIR", value = "/app/dbt" },
        { name = "BRONZE_BUCKET", value = var.bronze_bucket_name },
        { name = "SILVER_BUCKET", value = var.silver_bucket_name },
        { name = "GOLD_BUCKET", value = var.gold_bucket_name },
        { name = "ATHENA_WORKGROUP", value = var.athena_workgroup_name },
        { name = "GLUE_DATABASE", value = var.glue_database_name },
      ]

      # Example only - no such secret exists yet. Any dbt var that
      # shouldn't live in a plain environment variable (e.g. an optional
      # third-party API key referenced from dbt's own vars: block) would
      # be pulled in here by ARN at container start, the same pattern
      # used by the ingestion Lambdas' SECRET_ARN.
      # secrets = [
      #   { name = "SOME_DBT_VAR", valueFrom = "<secretsmanager-arn>" }
      # ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.dbt.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "dbt"
        }
      }
    }
  ])
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.dbt.arn
}

output "cluster_arn" {
  value = aws_ecs_cluster.orchestrator.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.dbt.repository_url
}

output "task_role_arn" {
  value = aws_iam_role.fargate_dbt_task.arn
}

output "execution_role_arn" {
  value = aws_iam_role.fargate_task_execution.arn
}
