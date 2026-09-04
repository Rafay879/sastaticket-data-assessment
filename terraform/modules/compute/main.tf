# Stub - filled in by the next prompt.
# Will hold: the ECS Fargate task definition that runs `dbt build`, its
# execution/task IAM roles, log group, and cluster wiring.
# See DEPLOYMENT.md section 2.

variable "project_prefix" {
  type = string
}

variable "environment" {
  type = string
}
