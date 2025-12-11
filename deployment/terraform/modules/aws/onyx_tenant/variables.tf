variable "tenant_name" {
  description = "Unique identifier for the tenant (e.g., customer-a)"
  type        = string
}

variable "alb_security_group_id" {
  description = "Security Group ID of the ALB to allow ingress traffic from"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., prod, dev)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ECS service will run"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the ECS tasks"
  type        = list(string)
}

variable "ecs_cluster_id" {
  description = "ID of the ECS Cluster to run the service in"
  type        = string
}

variable "alb_listener_arn" {
  description = "ARN of the ALB listener to attach the rule to"
  type        = string
}

variable "alb_dns_name" {
    description = "DNS name required for Host header routing"
    type = string
}

variable "domain_name" {
    description = "The domain name for this tenant (e.g., customer-a.onyx.app)"
    type = string
}

# Image Configs
variable "image_tag" {
  description = "Tag for Onyx images"
  type        = string
  default     = "latest"
}

variable "backend_image" {
  description = "Docker image for backend"
  type        = string
  default     = "onyxdotapp/onyx-backend"
}

variable "web_image" {
  description = "Docker image for web server"
  type        = string
  default     = "onyxdotapp/onyx-web-server"
}

variable "model_server_image" {
  description = "Docker image for model server"
  type        = string
  default     = "onyxdotapp/onyx-model-server"
}

# Database Configs
variable "postgres_host" {
  description = "Shared Postgres Host"
  type        = string
}

variable "postgres_user" {
    description = "Postgres User (potentially shared or tenant specific)"
    type = string
}

variable "postgres_password" {
    description = "Postgres Password"
    type = string
    sensitive = true
}

variable "postgres_db" {
    description = "Database name for this tenant"
    type = string
}

# Search Configs
variable "vespa_host" {
    description = "Shared Vespa Host URL"
    type = string
}

# App Configs
variable "auth_type" {
    description = "Authentication type (basic, cloud, etc.)"
    type = string
    default = "basic"
}

variable "container_cpu" {
    description = "CPU units for the task"
    type = number
    default = 1024 # 1 vCPU
}

variable "container_memory" {
    description = "Memory for the task"
    type = number
    default = 2048 # 2 GB
}
