locals {
  name_prefix = "${var.tenant_name}-${var.environment}"
  custom_tags = {
    Tenant      = var.tenant_name
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# SECURITY GROUPS
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_security_group" "ecs_task" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "Allow traffic from ALB"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.custom_tags
}

# ---------------------------------------------------------------------------------------------------------------------
# IAM ROLES
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_role" "execution_role" {
  name = "${local.name_prefix}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.custom_tags
}

resource "aws_iam_role_policy_attachment" "execution_role_policy" {
  role       = aws_iam_role.execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task_role" {
  name = "${local.name_prefix}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.custom_tags
}

# ---------------------------------------------------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "logs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30
  tags              = local.custom_tags
}

# ---------------------------------------------------------------------------------------------------------------------
# ECS TASK DEFINITION
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn

  # Container definitions - uses cloud embedding APIs (OpenAI/Cohere/etc.)
  # Model servers removed for cost savings. Configure embedding provider via Onyx Admin UI.
  container_definitions = jsonencode([
    # WEB SERVER
    {
      name      = "web_server"
      image     = "${var.web_image}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "INTERNAL_URL", value = "http://localhost:8080" },
        { name = "WEB_DOMAIN", value = var.domain_name },
        { name = "NEXT_PUBLIC_DISABLE_LOGOUT", value = "false" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.logs.name
          "awslogs-region"        = data.aws_region.current.id
          "awslogs-stream-prefix" = "web"
        }
      }
    },
    # API SERVER
    {
      name      = "api_server"
      image     = "${var.backend_image}:${var.image_tag}"
      essential = true
      command   = ["/bin/sh", "-c", "alembic upgrade head && echo 'Starting Onyx Api Server' && uvicorn onyx.main:app --host 0.0.0.0 --port 8080"]
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "AUTH_TYPE", value = var.auth_type },
        { name = "POSTGRES_HOST", value = var.postgres_host },
        { name = "POSTGRES_USER", value = var.postgres_user },
        { name = "POSTGRES_PASSWORD", value = var.postgres_password },
        { name = "POSTGRES_DB", value = var.postgres_db },
        { name = "VESPA_HOST", value = var.vespa_host },
        { name = "REDIS_HOST", value = var.redis_host },
        { name = "WEB_DOMAIN", value = var.domain_name },
        # Disable local model server - using cloud embedding APIs
        { name = "DISABLE_MODEL_SERVER", value = "True" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.logs.name
          "awslogs-region"        = data.aws_region.current.id
          "awslogs-stream-prefix" = "api"
        }
      }
    },
    # BACKGROUND WORKER
    {
      name      = "background"
      image     = "${var.backend_image}:${var.image_tag}"
      essential = true
      command   = ["/bin/sh", "-c", "/app/scripts/supervisord_entrypoint.sh"]
      environment = [
        { name = "POSTGRES_HOST", value = var.postgres_host },
        { name = "POSTGRES_USER", value = var.postgres_user },
        { name = "POSTGRES_PASSWORD", value = var.postgres_password },
        { name = "POSTGRES_DB", value = var.postgres_db },
        { name = "VESPA_HOST", value = var.vespa_host },
        { name = "REDIS_HOST", value = var.redis_host },
        { name = "WEB_DOMAIN", value = var.domain_name },
        # Disable local model server - using cloud embedding APIs
        { name = "DISABLE_MODEL_SERVER", value = "True" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.logs.name
          "awslogs-region"        = data.aws_region.current.id
          "awslogs-stream-prefix" = "background"
        }
      }
    }
  ])

  tags = local.custom_tags
}

# ---------------------------------------------------------------------------------------------------------------------
# LOAD BALANCER TARGET GROUP
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_lb_target_group" "target" {
  name        = "${local.name_prefix}-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = local.custom_tags
}

# ---------------------------------------------------------------------------------------------------------------------
# LOAD BALANCER LISTENER RULE
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_lb_listener_rule" "routing" {
  listener_arn = var.alb_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target.arn
  }

  condition {
    host_header {
      values = [var.alb_dns_name]
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ECS SERVICE
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${local.name_prefix}-service"
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs_task.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.target.arn
    container_name   = "web_server"
    container_port   = 3000
  }

  tags = local.custom_tags
}

data "aws_region" "current" {}
