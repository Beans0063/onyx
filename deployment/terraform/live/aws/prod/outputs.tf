# ---------------------------------------------------------------------------------------------------------------------
# OUTPUTS
# ---------------------------------------------------------------------------------------------------------------------

output "postgres_endpoint" {
  description = "PostgreSQL endpoint (host:port)"
  value       = module.postgres.endpoint
}

output "redis_endpoint" {
  description = "Redis endpoint"
  value       = module.redis.redis_endpoint
}

output "vespa_private_ip" {
  description = "Vespa EC2 private IP"
  value       = module.vespa_ec2.private_ip
}

output "alb_dns_name" {
  description = "ALB DNS name - point your CNAME records here"
  value       = aws_lb.main.dns_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}
