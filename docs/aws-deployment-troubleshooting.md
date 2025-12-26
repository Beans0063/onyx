# Onyx AWS Deployment Troubleshooting Guide

This guide documents common issues encountered during Onyx AWS deployments and provides systematic approaches to diagnose and resolve them.

---

## Table of Contents

1. [Terraform Destroy/Apply Cycle](#terraform-destroyapply-cycle)
2. [API/Nginx Routing Issues](#apinginx-routing-issues)
3. [ECS Task Troubleshooting](#ecs-task-troubleshooting)
4. [Database Issues](#database-issues)
5. [Redis/Cache Issues](#rediscache-issues)
6. [Vespa Vector Search Issues](#vespa-vector-search-issues)
7. [S3 Storage Issues](#s3-storage-issues)
8. [Resource Sizing Issues](#resource-sizing-issues)
9. [Health Check Failures](#health-check-failures)
10. [Quick Reference Commands](#quick-reference-commands)

---

## Terraform Destroy/Apply Cycle

This section documents what happens when you run `terraform destroy` followed by `terraform apply`, and the manual steps required to restore the environment.

### What Terraform Restores Automatically

| Resource | Recreated? | Notes |
|----------|------------|-------|
| VPC, Subnets, Security Groups | ✅ Yes | New IDs assigned |
| RDS PostgreSQL Instance | ✅ Yes | Empty database server (no data) |
| ElastiCache Redis | ✅ Yes | Empty cache |
| Vespa EC2 + Docker | ✅ Yes | New IP, container auto-starts via user_data |
| ECS Cluster, Service, Tasks | ✅ Yes | Same names |
| ALB, Listeners, Target Groups | ✅ Yes | **New DNS name** |
| ACM Certificate | ✅ Yes | Same validation records (no re-validation needed) |
| S3 Bucket | ✅ Yes | Empty bucket |
| IAM Roles and Policies | ✅ Yes | Same names |

### What Requires Manual Steps

#### 1. Tenant Database Creation (REQUIRED)

**Problem**: Terraform creates the RDS instance but NOT the per-tenant databases. The application will fail with:
```
sqlalchemy.exc.OperationalError: database "onyx_customer_a" does not exist
```

**Solution**: Create the database via SSM on the Vespa EC2 instance:
```bash
# Get Vespa instance ID
VESPA_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=onyx-prod-vespa" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Create database (get password from terraform.tfvars)
aws ssm send-command \
  --instance-ids $VESPA_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["PGPASSWORD=<your-password> psql -h onyx-prod-postgres.<id>.us-west-2.rds.amazonaws.com -U onyx_root -d postgres -c \"CREATE DATABASE onyx_customer_a;\""]'
```

**Future Improvement**: Consider adding a `null_resource` with `local-exec` provisioner to create tenant databases automatically, or use the PostgreSQL Terraform provider.

#### 2. DNS Update (REQUIRED)

**Problem**: The ALB gets a new DNS name after each `terraform apply`:
- Old: `onyx-prod-alb-1692407724.us-west-2.elb.amazonaws.com`
- New: `onyx-prod-alb-419508292.us-west-2.elb.amazonaws.com`

**Solution**: Update the CNAME record for your domain:
```bash
# Get new ALB DNS
terraform output alb_dns_name

# Update DNS (example for Porkbun, adjust for your provider)
# demo.vigilon.app → CNAME → <new-alb-dns>
```

**Verification**:
```bash
# Check DNS propagation
dig demo.vigilon.app +short
# Should return the new ALB DNS
```

**Future Improvement**: Migrate DNS to Route 53 and manage via Terraform for automatic updates.

#### 3. Force ECS Redeployment (IF NEEDED)

If the ECS task started before the database was created, force a new deployment:
```bash
aws ecs update-service \
  --cluster onyx-prod-cluster \
  --service customer-a-prod-service \
  --force-new-deployment
```

### What Data Is Lost

| Data Type | Location | Lost on Destroy? |
|-----------|----------|------------------|
| User accounts, settings | RDS PostgreSQL | ✅ Yes |
| Uploaded documents | S3 | ✅ Yes |
| Document embeddings/vectors | Vespa | ✅ Yes |
| Chat history | RDS PostgreSQL | ✅ Yes |
| Connector configurations | RDS PostgreSQL | ✅ Yes |
| Session data | Redis | ✅ Yes (minor) |

### Complete Restore Procedure

After `terraform apply`, run these steps in order:

```bash
# 1. Get new ALB DNS name
NEW_ALB=$(terraform output -raw alb_dns_name)
echo "Update DNS to: $NEW_ALB"

# 2. Create tenant database
VESPA_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=onyx-prod-vespa" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Get password from terraform.tfvars
PG_PASSWORD=$(grep postgres_password terraform.tfvars | cut -d'"' -f2)

aws ssm send-command \
  --instance-ids $VESPA_ID \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"PGPASSWORD=$PG_PASSWORD psql -h $(terraform output -raw postgres_endpoint | cut -d: -f1) -U onyx_root -d postgres -c \\\"CREATE DATABASE onyx_customer_a;\\\"\"]"

# 3. Wait for command to complete (10-15 seconds)
sleep 15

# 4. Force ECS redeployment to pick up the new database
aws ecs update-service \
  --cluster onyx-prod-cluster \
  --service customer-a-prod-service \
  --force-new-deployment

# 5. Update DNS CNAME (manual step - depends on your DNS provider)
echo "ACTION REQUIRED: Update demo.vigilon.app CNAME to $NEW_ALB"

# 6. Wait for ECS tasks to be running
watch -n 10 'aws ecs describe-services --cluster onyx-prod-cluster --services customer-a-prod-service --query "services[0].{running: runningCount, desired: desiredCount}"'
```

### Pause vs Destroy Comparison

| Aspect | Pause Script | Terraform Destroy |
|--------|--------------|-------------------|
| Monthly cost while stopped | ~$20-25 | ~$0 |
| Restore time | 5-10 minutes | 15-20 minutes |
| Data preserved | ✅ Yes | ❌ No |
| DNS update needed | ❌ No | ✅ Yes |
| Database creation needed | ❌ No | ✅ Yes |
| Use case | Hours/days of inactivity | Weeks+ or fresh start |

### Scripts Available

- `./scripts/pause-demo.sh` - Stop resources without destroying (preserves data)
- `./scripts/pause-demo.sh --resume` - Restart paused resources
- `./scripts/pause-demo.sh --status` - Check current state
- `./scripts/safe-destroy.sh` - Create backups before destroy (RDS snapshot, S3 copy)

---

## API/Nginx Routing Issues

Onyx requires an nginx reverse proxy to properly route requests between the web frontend and API backend. Without nginx, the application will appear to load but API requests will fail.

### Symptom: "Backend is currently unavailable"

**What You See**:
- Browser shows header: "The backend is currently unavailable"
- Login page loads but you cannot authenticate
- API requests like `curl https://demo.vigilon.app/api/me` return:
  ```json
  {"message": "This API is only available in development mode"}
  ```
  with HTTP 404

**Root Cause**: The ECS task is missing the nginx container. Without nginx:
- External requests hit the web server directly on port 3000
- The web server doesn't know how to handle `/api/*` routes
- The web server returns the "development mode" error for unknown routes

**Solution**: The ECS task definition must include 4 containers:
1. **nginx** (port 80) - Routes `/api/*` to api_server, everything else to web_server
2. **api_server** (port 8080) - Python backend
3. **web_server** (port 3000) - Next.js frontend
4. **background** - Background workers

The nginx container downloads the official Onyx nginx config and handles routing:
```
/api/*           → api_server:8080 (strips /api prefix)
/openapi.json    → api_server:8080
/*               → web_server:3000
```

### Symptom: 502 Bad Gateway on Non-API Routes

**What You See**:
- `/api/me` returns proper 403 (authentication required)
- `/auth/login` returns 502 Bad Gateway
- `/health` returns 502 Bad Gateway

**Nginx Error Log**:
```
connect() failed (111: Connection refused) while connecting to upstream,
upstream: "http://127.0.0.1:3000/health"
```

**Root Cause**: The Next.js web server is binding to the container's hostname IP instead of `0.0.0.0`. In ECS Fargate, Next.js binds to the ENI IP (e.g., `10.0.38.153`) rather than localhost, so nginx can't connect via `127.0.0.1`.

**Solution**: Add `HOSTNAME=0.0.0.0` environment variable to the web_server container:
```hcl
environment = [
  { name = "INTERNAL_URL", value = "http://localhost:8080" },
  { name = "WEB_DOMAIN", value = var.domain_name },
  { name = "NEXT_PUBLIC_DISABLE_LOGOUT", value = "false" },
  # Force Next.js to bind to 0.0.0.0 so nginx can connect via localhost
  { name = "HOSTNAME", value = "0.0.0.0" },
]
```

### Diagnosing Nginx Issues

#### Check Container Status
```bash
# Get task ID
TASK_ID=$(aws ecs list-tasks --cluster onyx-prod-cluster \
  --service-name customer-a-prod-service \
  --query 'taskArns[0]' --output text | rev | cut -d'/' -f1 | rev)

# Check all containers are running
aws ecs describe-tasks --cluster onyx-prod-cluster --tasks $TASK_ID \
  --query 'tasks[0].containers[*].{name:name,status:lastStatus}' --output table
```

#### Check Nginx Logs
```bash
# View nginx startup and error logs
aws logs get-log-events \
  --log-group-name /ecs/customer-a-prod \
  --log-stream-name nginx/nginx/$TASK_ID \
  --limit 100 --query 'events[*].message' --output text
```

**Healthy nginx startup looks like**:
```
Using API server host: localhost
Using web server host: localhost
Waiting for API server to boot up...
API server responded with 200, starting nginx...
start worker processes
```

**Unhealthy signs**:
```
API server responded with 000, retrying...  # API not ready yet (normal during startup)
connect() failed (111: Connection refused)  # Web server binding issue
```

#### Check API Server Logs
```bash
aws logs get-log-events \
  --log-group-name /ecs/customer-a-prod \
  --log-stream-name api/api_server/$TASK_ID \
  --limit 50 --query 'events[*].message' --output text
```

**Healthy API startup ends with**:
```
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8080
```

### Terraform Target Group Changes

When changing the target group port (e.g., from 3000 to 80 for nginx), Terraform may fail with:
```
Error: deleting ELBv2 Target Group: ResourceInUse:
Target group is currently in use by a listener or a rule
```

**Solution**: Add `create_before_destroy` lifecycle and use `name_prefix` instead of `name`:
```hcl
resource "aws_lb_target_group" "target" {
  name_prefix = substr("${local.name_prefix}-", 0, 6)
  port        = 80
  protocol    = "HTTP"
  # ...

  lifecycle {
    create_before_destroy = true
  }
}
```

This allows Terraform to:
1. Create a new target group with the new configuration
2. Update the listener rule to point to the new target group
3. Delete the old target group

### Container Architecture Summary

```
                    ┌─────────────────────────────────────────┐
                    │           ECS Fargate Task              │
                    │                                         │
  ALB:443 ──────────┼──▶ nginx:80                             │
                    │       │                                 │
                    │       ├── /api/* ──▶ api_server:8080    │
                    │       │                                 │
                    │       └── /*     ──▶ web_server:3000    │
                    │                                         │
                    │       background (no port)              │
                    └─────────────────────────────────────────┘
```

**Key Requirements**:
- ALB target group must point to nginx on port 80
- Security group must allow port 80 from ALB
- Load balancer config: `container_name = "nginx"`, `container_port = 80`
- Web server needs `HOSTNAME=0.0.0.0` for Next.js

---

## ECS Task Troubleshooting

### Symptoms
- Tasks stuck in PENDING state
- Tasks transitioning to STOPPED immediately
- Containers showing UNHEALTHY status
- Service not reaching desired count

### Diagnostic Steps

#### 1. Check Task Status
```bash
# Get the latest task for a service
TASK_ARN=$(aws ecs list-tasks --cluster onyx-prod-cluster \
  --service-name tenant-demo-service \
  --query 'taskArns[0]' --output text)

# Describe the task to see container status
aws ecs describe-tasks --cluster onyx-prod-cluster \
  --tasks $TASK_ARN \
  --query 'tasks[0].{
    lastStatus: lastStatus,
    desiredStatus: desiredStatus,
    stoppedReason: stoppedReason,
    containers: containers[*].{
      name: name,
      lastStatus: lastStatus,
      exitCode: exitCode,
      reason: reason
    }
  }'
```

#### 2. Check Stopped Task Reasons
```bash
# List recently stopped tasks
aws ecs list-tasks --cluster onyx-prod-cluster \
  --service-name tenant-demo-service \
  --desired-status STOPPED

# Describe stopped task to see why it failed
aws ecs describe-tasks --cluster onyx-prod-cluster \
  --tasks <stopped-task-arn> \
  --query 'tasks[0].{stoppedReason: stoppedReason, stopCode: stopCode}'
```

#### 3. View Container Logs
```bash
# Follow logs in real-time
aws logs tail /ecs/tenant-demo --follow

# Get last 100 log entries
aws logs tail /ecs/tenant-demo --since 1h

# Filter for errors only
aws logs filter-log-events \
  --log-group-name /ecs/tenant-demo \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000)
```

### Common Issues & Fixes

| Issue | Symptom | Fix |
|-------|---------|-----|
| Image pull failure | `CannotPullContainerError` | Check ECR permissions, verify image exists |
| Resource constraints | `RESOURCE:CPU` or `RESOURCE:MEMORY` | Increase task size or add capacity |
| Essential container exit | Task stops immediately | Check container logs for startup errors |

---

## Database Issues

### Issue 1: Connection String Port Duplication

**Symptom**: Application fails to connect with error like:
```
could not connect to server: Connection refused
Is the server running on host "xxx.rds.amazonaws.com:5432" and accepting TCP/IP connections on port 5432?
```

**Root Cause**: The RDS `endpoint` output includes the port (e.g., `host.rds.amazonaws.com:5432`), and if you append `:5432` again in the connection string, it becomes `host:5432:5432`.

**Diagnosis**:
```bash
# Check what your Terraform is outputting
terraform output postgres_endpoint

# Verify the format - should be host:port
# If using in connection string, don't add port again
```

**Fix**: Use the address (host only) instead of endpoint:
```hcl
# In postgres module outputs.tf
output "address" {
  description = "RDS instance address (without port)"
  value       = aws_db_instance.this.address
}

# In tenant module, use address + explicit port
POSTGRES_HOST = module.postgres.address
POSTGRES_PORT = "5432"
```

### Issue 2: Slow/Failing Migrations

**Symptom**:
- Migrations take 10+ minutes
- Container health checks fail during migration
- OOM errors during migration

**Root Cause**: Undersized RDS instance for running 267+ migrations simultaneously.

**Diagnosis**:
```bash
# Check RDS CPU utilization during migration
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=onyx-prod-postgres \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Average

# Check freeable memory
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name FreeableMemory \
  --dimensions Name=DBInstanceIdentifier,Value=onyx-prod-postgres \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Average
```

**Fix**:
1. Use at least `db.t4g.small` for initial migration (2 vCPU, 2GB RAM)
2. Can downgrade to `db.t4g.micro` after initial migration if cost is a concern
3. Add longer health check grace period (see [Health Check Failures](#health-check-failures))

### Issue 3: Cannot Connect to RDS

**Diagnosis**:
```bash
# Verify security group allows traffic from ECS
aws ec2 describe-security-groups \
  --group-ids <rds-security-group-id> \
  --query 'SecurityGroups[0].IpPermissions'

# Test connectivity from bastion/ECS task
# Use SSM to access an instance in the VPC
aws ssm start-session --target <instance-id>
# Then: nc -zv <rds-endpoint> 5432
```

**Common Fixes**:
- Ensure ECS security group is allowed in RDS security group inbound rules
- Verify RDS is in same VPC/subnets as ECS tasks
- Check that RDS is not publicly accessible if ECS is in private subnets

---

## Redis/Cache Issues

### Issue: Redis Connection Failed

**Symptom**:
```
Error connecting to Redis: Connection refused
# or
WRONGPASS invalid username-password pair
# or
SSL: CERTIFICATE_VERIFY_FAILED
```

**Root Cause**: ElastiCache Redis with TLS enabled requires both SSL configuration and authentication.

**Diagnosis**:
```bash
# Check ElastiCache cluster status
aws elasticache describe-replication-groups \
  --replication-group-id onyx-prod-redis \
  --query 'ReplicationGroups[0].{
    Status: Status,
    TransitEncryptionEnabled: TransitEncryptionEnabled,
    AuthTokenEnabled: AuthTokenEnabled
  }'

# Verify endpoint format
aws elasticache describe-replication-groups \
  --replication-group-id onyx-prod-redis \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint'
```

**Fix**: Ensure these environment variables are set in ECS task definition:
```hcl
environment = [
  {
    name  = "REDIS_HOST"
    value = "master.onyx-prod-redis.xxx.cache.amazonaws.com"
  },
  {
    name  = "REDIS_PORT"
    value = "6379"
  },
  {
    name  = "REDIS_SSL"
    value = "true"
  }
]

secrets = [
  {
    name      = "REDIS_PASSWORD"
    valueFrom = "arn:aws:secretsmanager:region:account:secret:redis-auth-token"
  }
]
```

---

## Vespa Vector Search Issues

### Issue: Vespa Container Down

**Symptom**: Application errors about vector search unavailable, or:
```
Connection refused to vespa:8080
```

**Root Cause**: Vespa runs on EC2 (not Fargate) and the Docker container may have stopped.

**Diagnosis**:
```bash
# Get Vespa instance ID
VESPA_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=onyx-prod-vespa" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Connect via SSM
aws ssm start-session --target $VESPA_ID

# Once connected, check Docker status
docker ps -a
docker logs vespa --tail 100
```

**Fix**:
```bash
# Restart the container
docker start vespa

# If container doesn't exist, recreate it
docker run -d --name vespa \
  --hostname vespa-container \
  -p 8080:8080 -p 19071:19071 \
  vespaengine/vespa:latest
```

### Issue: Vespa Not Reachable from ECS

**Diagnosis**:
```bash
# Check security group allows traffic on 8080 and 19071
aws ec2 describe-security-groups \
  --group-ids <vespa-sg-id> \
  --query 'SecurityGroups[0].IpPermissions'

# Verify Vespa EC2 is in correct subnet
aws ec2 describe-instances \
  --instance-ids $VESPA_ID \
  --query 'Reservations[0].Instances[0].{SubnetId: SubnetId, PrivateIp: PrivateIpAddress}'
```

---

## S3 Storage Issues

### Issue: S3 Access Denied

**Symptom**:
```
botocore.exceptions.ClientError: An error occurred (AccessDenied) when calling the PutObject operation
```

**Root Cause**: Either the bucket doesn't exist, or the ECS task role lacks permissions.

**Diagnosis**:
```bash
# Check if bucket exists
aws s3 ls | grep onyx-prod-file-store

# Check ECS task role permissions
TASK_ROLE=$(aws ecs describe-task-definition \
  --task-definition tenant-demo \
  --query 'taskDefinition.taskRoleArn' --output text)

aws iam list-attached-role-policies --role-name $(basename $TASK_ROLE)
aws iam list-role-policies --role-name $(basename $TASK_ROLE)
```

**Fix**: Ensure Terraform creates both the bucket and IAM policy:
```hcl
# S3 bucket
resource "aws_s3_bucket" "file_store" {
  bucket = "onyx-prod-file-store-${random_id.bucket_suffix.hex}"
}

# IAM policy for ECS task role
resource "aws_iam_role_policy" "s3_access" {
  name = "s3-file-store-access"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.file_store.arn,
          "${aws_s3_bucket.file_store.arn}/*"
        ]
      }
    ]
  })
}
```

---

## Resource Sizing Issues

### Issue: Out of Memory (OOM) Errors

**Symptom**:
- Container exits with code 137
- `OutOfMemoryError: Container killed due to memory usage`
- Tasks repeatedly stopping and restarting

**Root Cause**: Container memory limit too low for application requirements.

**Diagnosis**:
```bash
# Check container exit codes
aws ecs describe-tasks --cluster onyx-prod-cluster \
  --tasks $TASK_ARN \
  --query 'tasks[0].containers[*].{name: name, exitCode: exitCode, reason: reason}'

# Exit code 137 = killed by OOM
# Exit code 1 = application error
# Exit code 0 = normal exit

# Check CloudWatch for memory utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ClusterName,Value=onyx-prod-cluster Name=ServiceName,Value=tenant-demo-service \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Maximum
```

**Recommended Sizing for Onyx**:

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| API Container | 512 MB | 1024 MB |
| Background Container | 512 MB | 1024 MB |
| Web Container | 256 MB | 512 MB |
| **Total Task** | **1280 MB** | **2560 MB** |
| CPU | 512 (0.5 vCPU) | 1024 (1 vCPU) |

**Fix**: Update task definition:
```hcl
resource "aws_ecs_task_definition" "tenant" {
  # ...
  cpu    = "1024"  # 1 vCPU
  memory = "2048"  # 2 GB total for all containers

  container_definitions = jsonencode([
    {
      name   = "api"
      memory = 768
      memoryReservation = 512
      # ...
    },
    {
      name   = "background"
      memory = 768
      memoryReservation = 512
      # ...
    },
    {
      name   = "web"
      memory = 512
      memoryReservation = 256
      # ...
    }
  ])
}
```

---

## Health Check Failures

### Issue: Tasks Failing Health Checks During Startup

**Symptom**:
- ALB shows targets as unhealthy
- Tasks marked UNHEALTHY then stopped
- Service never reaches desired count

**Root Cause**: Migrations or startup take longer than health check timeout.

**Diagnosis**:
```bash
# Check target group health
TG_ARN=$(aws elbv2 describe-target-groups \
  --names tenant-demo-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-health --target-group-arn $TG_ARN

# Check health check configuration
aws elbv2 describe-target-groups \
  --target-group-arns $TG_ARN \
  --query 'TargetGroups[0].{
    HealthCheckPath: HealthCheckPath,
    HealthCheckIntervalSeconds: HealthCheckIntervalSeconds,
    HealthyThresholdCount: HealthyThresholdCount,
    UnhealthyThresholdCount: UnhealthyThresholdCount,
    HealthCheckTimeoutSeconds: HealthCheckTimeoutSeconds
  }'
```

**Fix**: Add health check grace period to ECS service:
```hcl
resource "aws_ecs_service" "tenant" {
  # ...

  health_check_grace_period_seconds = 600  # 10 minutes for migrations

  load_balancer {
    target_group_arn = aws_lb_target_group.tenant.arn
    container_name   = "web"
    container_port   = 3000
  }
}
```

Also configure appropriate target group health check:
```hcl
resource "aws_lb_target_group" "tenant" {
  # ...

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 10  # More attempts before marking unhealthy
    timeout             = 30
    interval            = 60  # Check every 60 seconds
    path                = "/health"
    matcher             = "200-299"
  }
}
```

---

## Quick Reference Commands

### ECS Status
```bash
# List all services in cluster
aws ecs list-services --cluster onyx-prod-cluster

# Get service status
aws ecs describe-services --cluster onyx-prod-cluster \
  --services tenant-demo-service \
  --query 'services[0].{
    runningCount: runningCount,
    desiredCount: desiredCount,
    status: status
  }'

# Force new deployment
aws ecs update-service --cluster onyx-prod-cluster \
  --service tenant-demo-service \
  --force-new-deployment
```

### Logs
```bash
# Tail logs
aws logs tail /ecs/tenant-demo --follow

# Search for errors in last hour
aws logs filter-log-events \
  --log-group-name /ecs/tenant-demo \
  --filter-pattern "?ERROR ?Exception ?error" \
  --start-time $(date -d '1 hour ago' +%s000)
```

### Database
```bash
# RDS status
aws rds describe-db-instances \
  --db-instance-identifier onyx-prod-postgres \
  --query 'DBInstances[0].{Status: DBInstanceStatus, Endpoint: Endpoint}'
```

### Redis
```bash
# ElastiCache status
aws elasticache describe-replication-groups \
  --replication-group-id onyx-prod-redis \
  --query 'ReplicationGroups[0].Status'
```

### Vespa
```bash
# Connect to Vespa EC2
VESPA_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=onyx-prod-vespa" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target $VESPA_ID

# Inside session: docker ps -a && docker logs vespa --tail 50
```

### ALB/Target Groups
```bash
# Check target health
TG_ARN=$(aws elbv2 describe-target-groups --names tenant-demo-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

---

## Troubleshooting Flowchart

```
Service Not Running
        │
        ▼
┌───────────────────┐
│ Check ECS Service │
│ describe-services │
└────────┬──────────┘
         │
         ▼
   runningCount = 0?
    ┌────┴────┐
   Yes       No ──► Check ALB target health
    │
    ▼
┌───────────────────┐
│ Check Task Status │
│  describe-tasks   │
└────────┬──────────┘
         │
         ▼
   Task STOPPED?
    ┌────┴────┐
   Yes       No ──► Task PENDING ──► Check resources/capacity
    │
    ▼
┌───────────────────┐
│ Check stoppedReason│
└────────┬──────────┘
         │
    ┌────┴────┬──────────────────┐
    ▼         ▼                  ▼
 OOM Error  Essential      Resource
 Exit 137   Container     Constraint
    │       Exited            │
    │         │               │
    ▼         ▼               ▼
 Increase   Check logs    Increase
 memory    for app error  task size
```

---

## Prevention Checklist

### Before Deploying a New Tenant or Making Changes

- [ ] RDS instance is at least `db.t4g.small` for initial migration
- [ ] ECS task has minimum 2GB memory, 1 vCPU
- [ ] Health check grace period is 600+ seconds
- [ ] S3 bucket exists and IAM policy is attached
- [ ] Redis environment includes `REDIS_SSL=true` and `REDIS_PASSWORD`
- [ ] Vespa EC2 security group allows ECS traffic on ports 8080, 19071
- [ ] PostgreSQL connection uses `address` (not `endpoint`) to avoid port duplication
- [ ] All secrets are in Secrets Manager and referenced correctly in task definition
- [ ] ECS task includes all 4 containers: nginx, api_server, web_server, background
- [ ] ALB target group points to nginx container on port 80
- [ ] Web server has `HOSTNAME=0.0.0.0` environment variable for Next.js
- [ ] Security group allows port 80 (not 3000) from ALB

### After Terraform Destroy/Apply

- [ ] Create tenant database: `CREATE DATABASE onyx_customer_a;`
- [ ] Update DNS CNAME to point to new ALB DNS name
- [ ] Verify ECS tasks are running: `aws ecs describe-services ...`
- [ ] Force ECS redeployment if tasks started before database existed
- [ ] Test site loads at https://demo.vigilon.app
- [ ] Verify API routing works: `curl https://demo.vigilon.app/api/me` returns 403 (not 404)
- [ ] Verify no "backend unavailable" message in browser
- [ ] Configure embedding provider in admin UI (if using cloud embeddings)

### Before Terraform Destroy (If Data Matters)

- [ ] Create RDS snapshot: `aws rds create-db-snapshot ...`
- [ ] Backup S3 bucket: `aws s3 sync s3://source s3://backup`
- [ ] Note current ALB DNS for reference
- [ ] Document any manual configurations made in the UI
