locals {
  name   = "onyx-prod"
  region = "us-west-2"
  tags = {
    Environment = "prod"
    Project     = "onyx"
  }
}

provider "aws" {
  region = local.region
  default_tags {
    tags = local.tags
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# SHARED INFRASTRUCTURE
# ---------------------------------------------------------------------------------------------------------------------

module "vpc" {
  source = "../../modules/aws/vpc"
  
  vpc_name = "${local.name}-vpc"
  tags     = local.tags
}

module "postgres" {
  source = "../../modules/aws/postgres"

  identifier    = "${local.name}-postgres"
  vpc_id        = module.vpc.vpc_id
  subnet_ids    = module.vpc.private_subnets
  ingress_cidrs = [module.vpc.vpc_cidr_block]
  username      = "onyx_root"
  password      = "ChangeMe123!" # In real life, use Secrets Manager
  tags          = local.tags
}

module "redis" {
  source        = "../../modules/aws/redis"
  name          = "${local.name}-redis"
  vpc_id        = module.vpc.vpc_id
  subnet_ids    = module.vpc.private_subnets
  instance_type = "cache.t4g.micro"
  ingress_cidrs = [module.vpc.vpc_cidr_block]
  tags          = local.tags
  auth_token    = "ChangeMeRedis!"
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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"
}

# ---------------------------------------------------------------------------------------------------------------------
# VESPA (EC2)
# ---------------------------------------------------------------------------------------------------------------------
# Simplified deployment of Vespa on a single EC2 instance for shared usage
module "vespa_ec2" {
  source = "terraform-aws-modules/ec2-instance/aws"
  name   = "${local.name}-vespa"

  instance_type          = "t3.xlarge"
  vpc_security_group_ids = [aws_security_group.vespa_sg.id]
  subnet_id              = module.vpc.private_subnets[0]
  
  user_data = <<-EOF
              #!/bin/bash
              yum install -y docker
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

module "tenant_a" {
  source = "../../modules/aws/onyx_tenant"
  
  tenant_name = "customer-a"
  environment = "prod"
  
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnets
  ecs_cluster_id      = aws_ecs_cluster.main.id
  alb_listener_arn    = aws_lb_listener.http.arn
  alb_security_group_id = aws_security_group.alb_sg.id
  
  alb_dns_name = "customer-a.example.com"
  domain_name  = "http://customer-a.example.com"
  
  postgres_host      = module.postgres.db_instance_address
  postgres_user      = "onyx_root"
  postgres_password  = "ChangeMe123!"
  postgres_db        = "onyx_customer_a" # Logic to ensure this DB exists needed elsewhere
  
  vespa_host         = module.vespa_ec2.private_ip
}

module "tenant_b" {
  source = "../../modules/aws/onyx_tenant"
  
  tenant_name = "customer-b"
  environment = "prod"
  
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnets
  ecs_cluster_id      = aws_ecs_cluster.main.id
  alb_listener_arn    = aws_lb_listener.http.arn
  alb_security_group_id = aws_security_group.alb_sg.id
  
  alb_dns_name = "customer-b.example.com"
  domain_name  = "http://customer-b.example.com"
  
  postgres_host      = module.postgres.db_instance_address
  postgres_user      = "onyx_root"
  postgres_password  = "ChangeMe123!"
  postgres_db        = "onyx_customer_b"
  
  vespa_host         = module.vespa_ec2.private_ip
}
