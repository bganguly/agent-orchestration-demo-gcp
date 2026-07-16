output "frontend_url" {
  value = "http://${aws_lb.main.dns_name}"
}

output "backend_url" {
  value = "http://${aws_lb.main.dns_name}:${var.be_port}"
}

output "backend_ecr_uri" {
  value = aws_ecr_repository.backend.repository_url
}

output "frontend_ecr_uri" {
  value = aws_ecr_repository.frontend.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "backend_service" {
  value = aws_ecs_service.backend.name
}

output "frontend_service" {
  value = aws_ecs_service.frontend.name
}

output "aws_region" {
  value = var.aws_region
}

output "name_prefix" {
  value = var.name_prefix
}
