#!/bin/bash
# Post-Apply Restore Script
# Run this after `terraform apply` to complete the setup
#
# Usage: ./scripts/post-apply-restore.sh

set -e

REGION="us-west-2"
CLUSTER="onyx-prod-cluster"
SERVICE="customer-a-prod-service"
TERRAFORM_DIR="deployment/terraform/live/aws/prod"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=========================================="
echo "Post-Apply Restore Script"
echo "=========================================="
echo ""

# Change to terraform directory
cd "$(dirname "$0")/../$TERRAFORM_DIR"

# 1. Get outputs
log_info "Getting Terraform outputs..."
NEW_ALB=$(terraform output -raw alb_dns_name 2>/dev/null)
PG_HOST=$(terraform output -raw postgres_endpoint 2>/dev/null | cut -d: -f1)

if [ -z "$NEW_ALB" ]; then
    log_error "Could not get ALB DNS. Make sure terraform apply completed successfully."
    exit 1
fi

echo ""
echo "New ALB DNS: $NEW_ALB"
echo "PostgreSQL Host: $PG_HOST"
echo ""

# 2. Get credentials from tfvars
log_info "Reading database credentials..."
if [ -f "terraform.tfvars" ]; then
    PG_PASSWORD=$(grep postgres_password terraform.tfvars | cut -d'"' -f2)
    PG_USER=$(grep postgres_username terraform.tfvars | cut -d'"' -f2 || echo "onyx_root")
    [ -z "$PG_USER" ] && PG_USER="onyx_root"
else
    log_error "terraform.tfvars not found. Cannot read database password."
    exit 1
fi

# 3. Get Vespa instance ID
log_info "Finding Vespa EC2 instance..."
VESPA_ID=$(aws ec2 describe-instances \
    --region $REGION \
    --filters "Name=tag:Name,Values=onyx-prod-vespa" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text)

if [ "$VESPA_ID" = "None" ] || [ -z "$VESPA_ID" ]; then
    log_error "Vespa instance not found or not running."
    exit 1
fi
echo "Vespa Instance: $VESPA_ID"

# 4. Create tenant database
log_info "Creating tenant database (onyx_customer_a)..."
CMD_ID=$(aws ssm send-command \
    --region $REGION \
    --instance-ids $VESPA_ID \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"PGPASSWORD='$PG_PASSWORD' psql -h $PG_HOST -U $PG_USER -d postgres -c \\\"CREATE DATABASE onyx_customer_a;\\\" 2>&1 || echo 'Database may already exist'\"]" \
    --query 'Command.CommandId' \
    --output text)

log_info "Waiting for database creation command..."
sleep 15

# Check command result
CMD_STATUS=$(aws ssm get-command-invocation \
    --region $REGION \
    --command-id $CMD_ID \
    --instance-id $VESPA_ID \
    --query 'Status' \
    --output text 2>/dev/null || echo "Unknown")

CMD_OUTPUT=$(aws ssm get-command-invocation \
    --region $REGION \
    --command-id $CMD_ID \
    --instance-id $VESPA_ID \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || echo "")

if [[ "$CMD_OUTPUT" == *"CREATE DATABASE"* ]] || [[ "$CMD_OUTPUT" == *"already exists"* ]]; then
    log_info "✓ Database ready"
else
    log_warn "Database command output: $CMD_OUTPUT"
fi

# 5. Force ECS redeployment
log_info "Forcing ECS service redeployment..."
aws ecs update-service \
    --region $REGION \
    --cluster $CLUSTER \
    --service $SERVICE \
    --force-new-deployment \
    --no-cli-pager > /dev/null

log_info "✓ ECS redeployment initiated"

# 6. Wait for service to stabilize
log_info "Waiting for ECS service to stabilize (this may take 5-10 minutes)..."
echo ""

MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    RUNNING=$(aws ecs describe-services \
        --region $REGION \
        --cluster $CLUSTER \
        --services $SERVICE \
        --query 'services[0].runningCount' \
        --output text)

    DESIRED=$(aws ecs describe-services \
        --region $REGION \
        --cluster $CLUSTER \
        --services $SERVICE \
        --query 'services[0].desiredCount' \
        --output text)

    echo -ne "\r  Running: $RUNNING / Desired: $DESIRED "

    if [ "$RUNNING" = "$DESIRED" ] && [ "$RUNNING" != "0" ]; then
        echo ""
        log_info "✓ ECS service is running!"
        break
    fi

    ATTEMPT=$((ATTEMPT + 1))
    sleep 20
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    log_warn "Timeout waiting for ECS. Check manually."
fi

echo ""
echo "=========================================="
echo "Post-Apply Restore Complete!"
echo "=========================================="
echo ""
echo "MANUAL STEP REQUIRED:"
echo ""
echo "  Update your DNS CNAME record:"
echo "  demo.vigilon.app → $NEW_ALB"
echo ""
echo "  DNS Provider: Porkbun (vigilon.app)"
echo "  1. Go to https://porkbun.com → Domain Management"
echo "  2. Find vigilon.app → DNS"
echo "  3. Update 'demo' CNAME to: $NEW_ALB"
echo ""
echo "After DNS update, verify at: https://demo.vigilon.app"
echo ""
