variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_prefix" {
  description = "Prefix applied to all resource names (S3 buckets, Lambda functions, IAM roles, etc.)."
  type        = string
  default     = "sastaticket"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# EventBridge schedule expression that triggers the daily pipeline run.
# AWS schedule syntax: cron(minutes hours day-of-month month day-of-week year)
# in UTC, or rate(value unit) for simple intervals.
# "cron(0 2 * * ? *)" = every day at 02:00 UTC. To run hourly instead, swap
# this for "rate(1 hour)" - EventBridge accepts either form.
variable "schedule_expression" {
  description = "EventBridge schedule expression that triggers the daily dbt run."
  type        = string
  default     = "cron(0 2 * * ? *)"
}

# No default on purpose - a real destination address is apply-time,
# per-deployment information, not something to hardcode a placeholder for.
# Pass via -var, a .tfvars file, or TF_VAR_alerts_email.
variable "alerts_email" {
  description = "Email address that receives pipeline failure/staleness alerts (modules/monitoring)."
  type        = string
}
