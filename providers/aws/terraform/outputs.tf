output "alb_dns_name" {
  description = "Public DNS of the ALB (point your domain / ACM cert here)."
  value       = aws_lb.main.dns_name
}

output "ecr_repository_url" {
  description = "ECR repository for the runtime image."
  value       = aws_ecr_repository.runtime.repository_url
}

output "ecs_cluster" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "migrate_task_definition" {
  description = "Task definition family for one-off migration runs (aws ecs run-task)."
  value       = aws_ecs_task_definition.migrate.family
}

output "db_address" {
  description = "RDS endpoint address (private)."
  value       = aws_db_instance.postgres.address
}

output "ci_deploy_role_arn" {
  description = "IAM role for GitHub Actions to assume via OIDC."
  value       = aws_iam_role.ci_deploy.arn
}
