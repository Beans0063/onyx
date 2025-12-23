locals {
  name = "onyx-prod"
  tags = {
    Environment = "prod"
    Project     = "onyx"
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = local.tags
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# SHARED INFRASTRUCTURE
# ---------------------------------------------------------------------------------------------------------------------

module "vpc" {
  source = "../../../modules/aws/vpc"
  
  vpc_name           = "${local.name}-vpc"
  single_nat_gateway = true # POC: Save cost by using 1 NAT GW instead of 1 per AZ
  tags               = local.tags
}

module "postgres" {
  source = "../../../modules/aws/postgres"

  identifier    = "${local.name}-postgres"
  vpc_id        = module.vpc.vpc_id
  subnet_ids    = module.vpc.private_subnets
  ingress_cidrs = [module.vpc.vpc_cidr_block]
  username      = var.postgres_username
  password      = var.postgres_password
  instance_type = "db.t4g.small" # POC: Small instance (micro was too slow for migrations)
  storage_gb    = 10              # POC: Minimal storage
  tags          = local.tags
}

module "redis" {
  source        = "../../../modules/aws/redis"
  name          = "${local.name}-redis"
  vpc_id        = module.vpc.vpc_id
  subnet_ids    = module.vpc.private_subnets
  instance_type = "cache.t4g.micro"
  ingress_cidrs = [module.vpc.vpc_cidr_block]
  tags          = local.tags
  auth_token    = var.redis_auth_token
}

resource "aws_security_group" "alb_sg" {
  name        = "${local.name}-alb-sg"
  description = "Allow HTTP/HTTPS traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false
}

# ---------------------------------------------------------------------------------------------------------------------
# SSL CERTIFICATE (ACM)
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_acm_certificate" "main" {
  domain_name               = "demo.vigilon.app"
  subject_alternative_names = ["*.vigilon.app"] # Wildcard for future tenants
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

# Output the DNS validation records (you'll need to add these to your DNS)
output "acm_validation_records" {
  description = "Add these CNAME records to your DNS to validate the certificate"
  value = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}

# Wait for certificate validation (will hang until DNS records are added)
resource "aws_acm_certificate_validation" "main" {
  certificate_arn = aws_acm_certificate.main.arn
  # Remove this line if you want terraform apply to complete before DNS validation
  # validation_record_fqdns = [for record in aws_acm_certificate.main.domain_validation_options : record.resource_record_name]
}

# ---------------------------------------------------------------------------------------------------------------------
# LOAD BALANCER LISTENERS
# ---------------------------------------------------------------------------------------------------------------------

# HTTP listener - redirects to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.main.arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }

  depends_on = [aws_acm_certificate_validation.main]
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"
}

# ---------------------------------------------------------------------------------------------------------------------
# S3 BUCKET (for file storage)
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_s3_bucket" "file_store" {
  bucket = "${local.name}-file-store"
  tags   = local.tags
}

resource "aws_s3_bucket_versioning" "file_store" {
  bucket = aws_s3_bucket.file_store.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "file_store" {
  bucket = aws_s3_bucket.file_store.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# GITHUB ACTIONS OIDC (for CI/CD to push to ECR)
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

resource "aws_iam_role" "github_actions" {
  name = "${local.name}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:Beans0063/onyx:*"
          }
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "${local.name}-github-ecr"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = [
          "arn:aws:ecr:us-west-2:008939990372:repository/onyx/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService"
        ]
        Resource = [
          "arn:aws:ecs:us-west-2:008939990372:service/onyx-prod-cluster/*"
        ]
      }
    ]
  })
}

output "github_actions_role_arn" {
  description = "ARN of the IAM role for GitHub Actions - add as AWS_ROLE_ARN secret"
  value       = aws_iam_role.github_actions.arn
}

# ---------------------------------------------------------------------------------------------------------------------
# VESPA (EC2)
# ---------------------------------------------------------------------------------------------------------------------

# IAM Role for SSM access (allows Session Manager connections)
resource "aws_iam_role" "vespa_ssm_role" {
  name = "${local.name}-vespa-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "vespa_ssm_policy" {
  role       = aws_iam_role.vespa_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "vespa_profile" {
  name = "${local.name}-vespa-profile"
  role = aws_iam_role.vespa_ssm_role.name
}

# Simplified deployment of Vespa on a single EC2 instance for shared usage
module "vespa_ec2" {
  source = "terraform-aws-modules/ec2-instance/aws"
  name   = "${local.name}-vespa"

  instance_type          = "t3.medium" # POC: Reduced from xlarge. Warning: Performance impactful.
  vpc_security_group_ids = [aws_security_group.vespa_sg.id]
  subnet_id              = module.vpc.private_subnets[0]
  iam_instance_profile   = aws_iam_instance_profile.vespa_profile.name

  user_data = <<-EOF
              #!/bin/bash
              yum install -y docker postgresql15
              service docker start
              docker run -d --name vespa --hostname vespa-container \
                -p 8081:8081 -p 19071:19071 \
                vespaengine/vespa
              EOF
  tags = local.tags
}

resource "aws_security_group" "vespa_sg" {
  name        = "${local.name}-vespa-sg"
  description = "Allow traffic to Vespa"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # Allow from ALB if needed (admin console)
    cidr_blocks = [module.vpc.vpc_cidr_block] # Allow from VPC (ECS tasks)
  }
  
  ingress {
    from_port   = 19071
    to_port     = 19071
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# TENANTS
# ---------------------------------------------------------------------------------------------------------------------

module "tenant_demo" {
  source = "../../../modules/aws/onyx_tenant"

  tenant_name = "customer-a"
  environment = "prod"

  vpc_id                = module.vpc.vpc_id
  private_subnet_ids    = module.vpc.private_subnets
  ecs_cluster_id        = aws_ecs_cluster.main.id
  alb_listener_arn      = aws_lb_listener.https.arn
  alb_security_group_id = aws_security_group.alb_sg.id

  alb_dns_name = "demo.vigilon.app"
  domain_name  = "https://demo.vigilon.app"

  # Use ECR images instead of Docker Hub (avoids rate limiting)
  web_image     = "008939990372.dkr.ecr.us-west-2.amazonaws.com/onyx/web-server"
  backend_image = "008939990372.dkr.ecr.us-west-2.amazonaws.com/onyx/backend"

  # Shared services (use address, not endpoint - endpoint includes port)
  postgres_host     = module.postgres.address
  postgres_user     = var.postgres_username
  postgres_password = var.postgres_password
  postgres_db       = "onyx_customer_a"
  vespa_host        = module.vespa_ec2.private_ip
  redis_host        = module.redis.redis_endpoint
  redis_password    = var.redis_auth_token
  redis_ssl         = true

  # Cloud embeddings - configure via Onyx Admin UI after deployment
  # No model servers needed - saves ~$60/month!

  # S3 file storage
  s3_bucket_name = aws_s3_bucket.file_store.id
  s3_bucket_arn  = aws_s3_bucket.file_store.arn

  container_cpu    = 1024 # POC: 1 vCPU (increased for migrations)
  container_memory = 2048 # POC: 2 GB RAM (increased for migrations)
}

# Uncomment to add another tenant
# module "tenant_b" {
#   source = "../../../modules/aws/onyx_tenant"
#
#   tenant_name = "customer-b"
#   environment = "prod"
#
#   vpc_id                = module.vpc.vpc_id
#   private_subnet_ids    = module.vpc.private_subnets
#   ecs_cluster_id        = aws_ecs_cluster.main.id
#   alb_listener_arn      = aws_lb_listener.https.arn
#   alb_security_group_id = aws_security_group.alb_sg.id
#
#   alb_dns_name = "customer-b.vigilon.app"
#   domain_name  = "https://customer-b.vigilon.app"
#
#   web_image     = "008939990372.dkr.ecr.us-west-2.amazonaws.com/onyx/web-server"
#   backend_image = "008939990372.dkr.ecr.us-west-2.amazonaws.com/onyx/backend"
#
#   postgres_host     = module.postgres.endpoint
#   postgres_user     = var.postgres_username
#   postgres_password = var.postgres_password
#   postgres_db       = "onyx_customer_b"
#   vespa_host        = module.vespa_ec2.private_ip
#   redis_host        = module.redis.redis_endpoint
#
#   container_cpu    = 512
#   container_memory = 1024
# }
