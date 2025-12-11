output "service_name" {
  value = aws_ecs_service.app.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.app.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.target.arn
}
