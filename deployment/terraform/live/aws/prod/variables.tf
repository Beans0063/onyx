# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES (no defaults - must be provided)
# ---------------------------------------------------------------------------------------------------------------------

variable "postgres_password" {
  description = "Master password for PostgreSQL"
  type        = string
  sensitive   = true
}

variable "redis_auth_token" {
  description = "Auth token for Redis"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES (have sensible defaults)
# ---------------------------------------------------------------------------------------------------------------------

variable "postgres_username" {
  description = "Master username for PostgreSQL"
  type        = string
  default     = "onyx_root"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}
