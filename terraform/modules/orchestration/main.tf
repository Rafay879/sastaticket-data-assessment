# Stub - filled in by the next prompt.
# Will hold: the Step Functions state machine (Parallel ingestion, Choice,
# Retry, Catch) and the EventBridge rule that triggers it on
# var.schedule_expression. See DEPLOYMENT.md section 2.

variable "project_prefix" {
  type = string
}

variable "environment" {
  type = string
}
