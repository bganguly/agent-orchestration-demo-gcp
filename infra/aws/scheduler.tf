resource "aws_scheduler_schedule" "start_backend" {
  name       = "${var.name_prefix}-start-be"
  group_name = "default"
  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 8 ? * MON-FRI *)"
  schedule_expression_timezone = "America/Los_Angeles"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ Cluster = aws_ecs_cluster.main.name, Service = aws_ecs_service.backend.name, DesiredCount = 1 })
  }
}

resource "aws_scheduler_schedule" "stop_backend" {
  name       = "${var.name_prefix}-stop-be"
  group_name = "default"
  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 17 ? * MON-FRI *)"
  schedule_expression_timezone = "America/Los_Angeles"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ Cluster = aws_ecs_cluster.main.name, Service = aws_ecs_service.backend.name, DesiredCount = 0 })
  }
}

resource "aws_scheduler_schedule" "start_frontend" {
  name       = "${var.name_prefix}-start-fe"
  group_name = "default"
  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 8 ? * MON-FRI *)"
  schedule_expression_timezone = "America/Los_Angeles"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ Cluster = aws_ecs_cluster.main.name, Service = aws_ecs_service.frontend.name, DesiredCount = 1 })
  }
}

resource "aws_scheduler_schedule" "stop_frontend" {
  name       = "${var.name_prefix}-stop-fe"
  group_name = "default"
  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 17 ? * MON-FRI *)"
  schedule_expression_timezone = "America/Los_Angeles"
  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ Cluster = aws_ecs_cluster.main.name, Service = aws_ecs_service.frontend.name, DesiredCount = 0 })
  }
}
