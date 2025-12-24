# Onyx AWS Deployment Troubleshooting Guide

This guide documents common issues encountered during Onyx AWS deployments and provides systematic approaches to diagnose and resolve them.

---

## Table of Contents

1. [Terraform Destroy/Apply Cycle](#terraform-destroyapply-cycle)
2. [ECS Task Troubleshooting](#ecs-task-troubleshooting)
3. [Database Issues](#database-issues)
4. [Redis/Cache Issues](#rediscache-issues)
5. [Vespa Vector Search Issues](#vespa-vector-search-issues)
6. [S3 Storage Issues](#s3-storage-issues)
7. [Resource Sizing Issues](#resource-sizing-issues)
8. [Health Check Failures](#health-check-failures)
9. [Quick Reference Commands](#quick-reference-commands)

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

### After Terraform Destroy/Apply

- [ ] Create tenant database: `CREATE DATABASE onyx_customer_a;`
- [ ] Update DNS CNAME to point to new ALB DNS name
- [ ] Verify ECS tasks are running: `aws ecs describe-services ...`
- [ ] Force ECS redeployment if tasks started before database existed
- [ ] Test site loads at https://demo.vigilon.app
- [ ] Configure embedding provider in admin UI (if using cloud embeddings)

### Before Terraform Destroy (If Data Matters)

- [ ] Create RDS snapshot: `aws rds create-db-snapshot ...`
- [ ] Backup S3 bucket: `aws s3 sync s3://source s3://backup`
- [ ] Note current ALB DNS for reference
- [ ] Document any manual configurations made in the UI
