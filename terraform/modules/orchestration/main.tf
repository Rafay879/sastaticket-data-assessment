# The Step Functions state machine that ties ingestion -> conditional
# crawl -> dbt build together, its EventBridge daily trigger, and the two
# IAM roles involved (the state machine's own execution role, and the
# role EventBridge assumes to start an execution). See DEPLOYMENT.md
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

variable "schedule_expression" {
  type = string
}

variable "lambda_function_arns" {
  description = "Map of source name (gds/lcc/payments/reference) to ingestion Lambda ARN, from module.ingestion."
  type        = map(string)
}

variable "cluster_arn" {
  type = string
}

variable "task_definition_arn" {
  type = string
}

variable "fargate_task_role_arn" {
  type = string
}

variable "fargate_execution_role_arn" {
  type = string
}

variable "glue_crawler_name" {
  type = string
}

variable "sns_topic_arn" {
  type = string
}

data "aws_caller_identity" "current" {}

# Uses the account's default VPC/subnets - no VPC resources are created
# here. A real deployment would run the dbt task in private subnets via a
# dedicated VPC module (not built in this skeleton - see
# terraform/README.md "What's NOT here").
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_security_group" "default" {
  vpc_id = data.aws_vpc.default.id
  name   = "default"
}

locals {
  name_prefix     = "${var.project_prefix}-${var.environment}"
  dbt_task_family = "${local.name_prefix}-dbt"

  # One branch per ingestion Lambda. Each branch is intentionally a single
  # Task state (not a Map/nested Parallel) - four fixed, known sources,
  # not a dynamic list.
  ingest_branches = [
    for source in ["gds", "lcc", "payments", "reference"] : {
      StartAt = "Invoke${title(source)}Ingestion"
      States = {
        "Invoke${title(source)}Ingestion" = {
          Type     = "Task"
          Resource = "arn:aws:states:::lambda:invoke"
          Parameters = {
            FunctionName = var.lambda_function_arns[source]
            "Payload.$"  = "$"
          }
          # Reshape the wrapped Lambda response down to just the field
          # AggregateIngestResults needs, so the math below doesn't have
          # to reach through .Payload on every element.
          ResultSelector = {
            "new_records.$" = "$.Payload.new_records"
          }
          # Transient Lambda service hiccups, not application errors -
          # a bad response from the upstream API is not caught here on
          # purpose, so it surfaces as a real failure instead of being
          # retried into a false sense of success.
          Retry = [
            {
              ErrorEquals     = ["Lambda.ServiceException", "Lambda.SdkClientException"]
              IntervalSeconds = 5
              MaxAttempts     = 3
              BackoffRate     = 2
            }
          ]
          End = true
        }
      }
    }
  ]

  state_machine_definition = {
    Comment = "Ingest all four sources in parallel, crawl bronze only if new records arrived, then run dbt build."
    StartAt = "IngestSources"
    States = {
      IngestSources = {
        Type     = "Parallel"
        Branches = local.ingest_branches
        # Catch at the Parallel level, not per-branch: any branch that
        # exhausts its own Retry above fails the whole Parallel state,
        # which is caught once here rather than four times.
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error"
            Next        = "NotifyFailure"
          }
        ]
        Next = "AggregateIngestResults"
      }

      # Sums new_records across all four branches. States.MathAdd only
      # takes two operands, so three calls are chained to add four
      # numbers.
      AggregateIngestResults = {
        Type = "Pass"
        Parameters = {
          "total_new_records.$" = "States.MathAdd(States.MathAdd(States.MathAdd($[0].new_records, $[1].new_records), $[2].new_records), $[3].new_records)"
        }
        Next = "NewDataArrived"
      }

      NewDataArrived = {
        Type = "Choice"
        Choices = [
          {
            Variable           = "$.total_new_records"
            NumericGreaterThan = 0
            Next               = "RunCrawler"
          }
        ]
        # No new records anywhere - skip both the crawl and the dbt
        # build entirely rather than paying for a run with nothing new
        # to process.
        Default = "NoOpSuccess"
      }

      RunCrawler = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:startCrawler"
        Parameters = {
          Name = var.glue_crawler_name
        }
        Retry = [
          {
            ErrorEquals     = ["Glue.ConcurrentRunsExceededException"]
            IntervalSeconds = 30
            MaxAttempts     = 3
            BackoffRate     = 2
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error"
            Next        = "NotifyFailure"
          }
        ]
        Next = "WaitForCrawler"
      }

      # Polling loop (Wait + GetCrawler + Choice) rather than a single
      # blocking call: Step Functions has no `.sync` integration for Glue
      # crawlers the way it does for ECS RunTask below. A push-based
      # alternative worth knowing about: an EventBridge rule on Glue
      # Crawler State Change events feeding back into this execution via
      # a waitForTaskToken callback - not used here, to avoid an extra
      # EventBridge rule + IAM wiring in an already-large skeleton; the
      # polling loop is more portable and easier to review.
      WaitForCrawler = {
        Type    = "Wait"
        Seconds = 30
        Next    = "GetCrawlerStatus"
      }

      GetCrawlerStatus = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:glue:getCrawler"
        Parameters = {
          Name = var.glue_crawler_name
        }
        Next = "CrawlerFinished?"
      }

      "CrawlerFinished?" = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.Crawler.State"
            StringEquals = "READY"
            Next         = "RunDbtBuild"
          }
        ]
        Default = "WaitForCrawler"
      }

      RunDbtBuild = {
        Type = "Task"
        # .sync: waits for the ECS task to actually finish (and fails the
        # state on a non-zero container exit code) rather than firing
        # RunTask and moving on immediately.
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          Cluster        = var.cluster_arn
          TaskDefinition = var.task_definition_arn
          LaunchType     = "FARGATE"
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = data.aws_subnets.default.ids
              SecurityGroups = [data.aws_security_group.default.id]
              AssignPublicIp = "ENABLED"
            }
          }
        }
        # A single retry: ECS.AmazonECSException here is almost always a
        # transient capacity/throttling error from the ECS control plane
        # itself, not a dbt failure. A dbt failure surfaces as a non-zero
        # container exit code, which .sync turns into a state failure
        # that is NOT retried here - a broken model should fail loudly,
        # not silently retry into the same broken result.
        Retry = [
          {
            ErrorEquals     = ["ECS.AmazonECSException"]
            IntervalSeconds = 15
            MaxAttempts     = 1
            BackoffRate     = 2
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            ResultPath  = "$.error"
            Next        = "NotifyFailure"
          }
        ]
        Next = "Success"
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn    = var.sns_topic_arn
          "Message.$" = "States.Format('${local.name_prefix}-orchestrator failed: {} - {}', $.error.Error, $.error.Cause)"
        }
        Next = "Fail"
      }

      Fail = {
        Type = "Fail"
      }

      NoOpSuccess = {
        Type = "Succeed"
      }

      Success = {
        Type = "Succeed"
      }
    }
  }
}

resource "aws_iam_role" "step_functions_execution" {
  name = "${local.name_prefix}-step-functions-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "step_functions_execution" {
  name = "${local.name_prefix}-step-functions-execution"

  # See ../../policies/step_functions_execution.json for the full
  # statement-by-statement rationale (InvokeIngestionLambdas,
  # RunFargateTask, PassRolesToECS, StartGlueCrawler, PublishAlerts).
  policy = templatefile("${path.module}/../../policies/step_functions_execution.json", {
    region                     = var.aws_region
    account_id                 = data.aws_caller_identity.current.account_id
    project_prefix             = var.project_prefix
    environment                = var.environment
    dbt_task_family            = local.dbt_task_family
    fargate_task_role_arn      = var.fargate_task_role_arn
    fargate_execution_role_arn = var.fargate_execution_role_arn
    glue_crawler_name          = var.glue_crawler_name
    sns_topic_arn              = var.sns_topic_arn
  })
}

resource "aws_iam_role_policy_attachment" "step_functions_execution" {
  role       = aws_iam_role.step_functions_execution.name
  policy_arn = aws_iam_policy.step_functions_execution.arn
}

resource "aws_sfn_state_machine" "orchestrator" {
  name       = "${local.name_prefix}-orchestrator"
  role_arn   = aws_iam_role.step_functions_execution.arn
  definition = jsonencode(local.state_machine_definition)
}

# -----------------------------------------------------------------------
# Daily trigger
# -----------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name                = "${local.name_prefix}-daily-trigger"
  schedule_expression = var.schedule_expression
}

resource "aws_iam_role" "eventbridge_invoke_stepfn" {
  name = "${local.name_prefix}-eventbridge-invoke-stepfn"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_invoke_stepfn" {
  name = "${local.name_prefix}-eventbridge-invoke-stepfn"
  role = aws_iam_role.eventbridge_invoke_stepfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartOrchestratorExecution"
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.orchestrator.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_target" "orchestrator" {
  rule     = aws_cloudwatch_event_rule.daily_trigger.name
  arn      = aws_sfn_state_machine.orchestrator.arn
  role_arn = aws_iam_role.eventbridge_invoke_stepfn.arn
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.orchestrator.arn
}

output "event_rule_arn" {
  value = aws_cloudwatch_event_rule.daily_trigger.arn
}
