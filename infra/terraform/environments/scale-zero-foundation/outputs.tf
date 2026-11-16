output "vpc_id" {
  description = "Scale-zero VPC id."
  value       = aws_vpc.this.id
}

output "worker_subnet_ids" {
  description = "Public-route subnets for bounded tasks. RunTask must explicitly assign a public IP."
  value       = values(aws_subnet.worker)[*].id
}

output "data_subnet_ids" {
  description = "Private subnets with no internet default route."
  value       = values(aws_subnet.data)[*].id
}

output "worker_security_group_id" {
  description = "No-ingress security group for bounded workers."
  value       = aws_security_group.worker.id
}

output "lambda_security_group_id" {
  description = "No-ingress security group reserved for the Phase 4 API Lambda integration."
  value       = aws_security_group.lambda.id
}

output "aurora_cluster_endpoint" {
  description = "Private Aurora writer endpoint."
  value       = aws_rds_cluster.this.endpoint
}

output "aurora_master_secret_arn" {
  description = "RDS-managed master credential secret."
  value       = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

output "artifact_bucket_name" {
  description = "Private, lifecycle-managed artifact bucket."
  value       = aws_s3_bucket.artifacts.bucket
}

output "ssm_parameter_prefix" {
  description = "Path under which runtime secrets are written out-of-band as SecureString parameters (KMS key: kms_key_arn)."
  value       = local.ssm_prefix
}

output "kms_key_arn" {
  description = "Customer-managed key for Aurora, artifacts, logs and SecureString parameters."
  value       = aws_kms_key.data.arn
}

output "app_db_role" {
  description = "IAM-authenticated runtime database role created by the migration task."
  value       = local.app_db_role
}

output "api_url" {
  description = "Public API base URL (no trailing slash)."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "api_function_name" {
  value = aws_lambda_function.api.function_name
}

output "sweep_function_name" {
  value = aws_lambda_function.sweep.function_name
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.investigation.arn
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "migrate_task_definition" {
  description = "Family of the one-off migration task (run with the worker subnets and security group)."
  value       = aws_ecs_task_definition.migrate.family
}

output "ecr_backend_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "ecr_lambda_repository_url" {
  value = aws_ecr_repository.lambda.repository_url
}

output "github_release_role_arn" {
  description = "OIDC role for the release workflow (environment scale-zero)."
  value       = aws_iam_role.github_release.arn
}

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "github_plan_role_arn" {
  description = "Read-only GitHub Actions OIDC role for reviewed plans from main."
  value       = aws_iam_role.github_plan.arn
}
