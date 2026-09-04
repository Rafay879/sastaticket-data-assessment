# Stub - filled in by the next prompt.
# Will hold: the SNS topic for pipeline failure alerts, and the CloudWatch
# alarms/EventBridge rules that publish to it. See DEPLOYMENT.md section 4.

variable "project_prefix" {
  type = string
}

variable "environment" {
  type = string
}
