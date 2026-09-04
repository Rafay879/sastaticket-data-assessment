# The SNS topic ingestion/orchestration failures publish to, and the
# dead-man's-switch alarm that fires if the pipeline hasn't succeeded in
# 24h (catching a run that never started at all, not just one that
# failed loudly). See DEPLOYMENT.md section 4.

variable "project_prefix" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "alerts_email" {
  type = string
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_prefix}-${var.environment}"

  # Constructed deterministically from the naming convention rather than
  # taken as a module output from orchestration: orchestration's own IAM
  # policy needs THIS module's sns_topic_arn, so a real
  # module.orchestration.state_machine_arn -> module.monitoring dependency
  # would create a cycle (orchestration depends on monitoring, monitoring
  # would depend on orchestration). The state machine's name is fully
  # predictable from {project_prefix}-{environment}-orchestrator, so no
  # output/dependency is needed in this direction.
  state_machine_arn = "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${local.name_prefix}-orchestrator"
}

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

# SNS email needs manual click-to-confirm on first apply.
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alerts_email
}

# Dead-man's-switch: if the state machine hasn't recorded a successful
# execution in the last 24h, something is wrong even if nothing "failed"
# loudly (e.g. EventBridge itself never fired, or the state machine never
# even started). Period matches the daily schedule - would need
# tightening to match an hourly schedule.
resource "aws_cloudwatch_metric_alarm" "pipeline_stale" {
  alarm_name  = "${local.name_prefix}-pipeline-stale"
  namespace   = "AWS/States"
  metric_name = "ExecutionsSucceeded"

  dimensions = {
    StateMachineArn = local.state_machine_arn
  }

  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  # No data at all (e.g. the pipeline never ran) must trip the alarm too,
  # not be treated as "nothing to alarm on" - the default CloudWatch
  # behavior would silently miss a total outage.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "alarm_name" {
  value = aws_cloudwatch_metric_alarm.pipeline_stale.alarm_name
}
