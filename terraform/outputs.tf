# Populated once modules are filled in (see prompt 9).

# output "bronze_bucket_name" {
#   description = "S3 bucket holding raw, untransformed feeds."
#   value       = module.storage.bronze_bucket_name
# }

# output "silver_bucket_name" {
#   description = "S3 bucket holding staged/intermediate dbt tables."
#   value       = module.storage.silver_bucket_name
# }

# output "gold_bucket_name" {
#   description = "S3 bucket holding mart-layer output tables."
#   value       = module.storage.gold_bucket_name
# }

# output "dbt_task_definition_arn" {
#   description = "ARN of the ECS Fargate task definition that runs dbt build."
#   value       = module.compute.dbt_task_definition_arn
# }

# output "state_machine_arn" {
#   description = "ARN of the Step Functions state machine orchestrating ingestion + dbt."
#   value       = module.orchestration.state_machine_arn
# }

# output "sns_topic_arn" {
#   description = "ARN of the SNS topic used for pipeline failure alerts."
#   value       = module.monitoring.sns_topic_arn
# }
