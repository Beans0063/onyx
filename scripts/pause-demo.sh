#!/bin/bash
# Pause Onyx Demo Environment
# Reduces AWS costs by stopping/scaling down resources
#
# Usage: ./scripts/pause-demo.sh [--resume]

set -e

CLUSTER="onyx-prod-cluster"
SERVICE="tenant-demo-service"
RDS_INSTANCE="onyx-prod-postgres"
REGION="us-west-2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

get_vespa_instance_id() {
    aws ec2 describe-instances \
        --region $REGION \
        --filters "Name=tag:Name,Values=onyx-prod-vespa" "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text
}

pause_environment() {
    log_info "Pausing Onyx demo environment..."
    echo ""

    # 1. Scale ECS to 0
    log_info "Scaling ECS service to 0 tasks..."
    aws ecs update-service \
        --region $REGION \
        --cluster $CLUSTER \
        --service $SERVICE \
        --desired-count 0 \
        --no-cli-pager > /dev/null
    log_info "✓ ECS service scaled to 0"

    # 2. Stop RDS
    log_info "Stopping RDS instance (can remain stopped for 7 days)..."
    RDS_STATUS=$(aws rds describe-db-instances \
        --region $REGION \
        --db-instance-identifier $RDS_INSTANCE \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null || echo "not-found")

    if [ "$RDS_STATUS" = "available" ]; then
        aws rds stop-db-instance \
            --region $REGION \
            --db-instance-identifier $RDS_INSTANCE \
            --no-cli-pager > /dev/null
        log_info "✓ RDS stop initiated"
    elif [ "$RDS_STATUS" = "stopped" ]; then
        log_info "✓ RDS already stopped"
    else
        log_warn "RDS status: $RDS_STATUS (may need manual intervention)"
    fi

    # 3. Stop Vespa EC2
    log_info "Stopping Vespa EC2 instance..."
    VESPA_ID=$(get_vespa_instance_id)
    if [ "$VESPA_ID" != "None" ] && [ -n "$VESPA_ID" ]; then
        VESPA_STATE=$(aws ec2 describe-instances \
            --region $REGION \
            --instance-ids $VESPA_ID \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text)

        if [ "$VESPA_STATE" = "running" ]; then
            aws ec2 stop-instances \
                --region $REGION \
                --instance-ids $VESPA_ID \
                --no-cli-pager > /dev/null
            log_info "✓ Vespa EC2 stop initiated"
        else
            log_info "✓ Vespa EC2 already stopped (state: $VESPA_STATE)"
        fi
    else
        log_warn "Vespa instance not found"
    fi

    echo ""
    log_info "=========================================="
    log_info "Environment paused!"
    log_info "=========================================="
    echo ""
    echo "Estimated savings: ~\$70-100/month while paused"
    echo ""
    echo "Still incurring costs for:"
    echo "  - ALB (~\$16/mo) - cannot be paused without deletion"
    echo "  - RDS storage (~\$3-5/mo)"
    echo "  - EBS volumes (~\$2-3/mo)"
    echo ""
    echo "NOTE: RDS will auto-restart after 7 days. Set a reminder!"
    echo ""
    echo "To resume: ./scripts/pause-demo.sh --resume"
}

resume_environment() {
    log_info "Resuming Onyx demo environment..."
    echo ""

    # 1. Start RDS first (takes longest)
    log_info "Starting RDS instance..."
    RDS_STATUS=$(aws rds describe-db-instances \
        --region $REGION \
        --db-instance-identifier $RDS_INSTANCE \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null || echo "not-found")

    if [ "$RDS_STATUS" = "stopped" ]; then
        aws rds start-db-instance \
            --region $REGION \
            --db-instance-identifier $RDS_INSTANCE \
            --no-cli-pager > /dev/null
        log_info "✓ RDS start initiated (takes 5-10 minutes)"
    elif [ "$RDS_STATUS" = "available" ]; then
        log_info "✓ RDS already running"
    else
        log_warn "RDS status: $RDS_STATUS"
    fi

    # 2. Start Vespa EC2
    log_info "Starting Vespa EC2 instance..."
    VESPA_ID=$(get_vespa_instance_id)
    if [ "$VESPA_ID" != "None" ] && [ -n "$VESPA_ID" ]; then
        VESPA_STATE=$(aws ec2 describe-instances \
            --region $REGION \
            --instance-ids $VESPA_ID \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text)

        if [ "$VESPA_STATE" = "stopped" ]; then
            aws ec2 start-instances \
                --region $REGION \
                --instance-ids $VESPA_ID \
                --no-cli-pager > /dev/null
            log_info "✓ Vespa EC2 start initiated"
        else
            log_info "✓ Vespa EC2 already running (state: $VESPA_STATE)"
        fi
    else
        log_warn "Vespa instance not found"
    fi

    # 3. Wait for dependencies before starting ECS
    log_info "Waiting for RDS to become available..."
    echo "  (This may take 5-10 minutes)"

    while true; do
        RDS_STATUS=$(aws rds describe-db-instances \
            --region $REGION \
            --db-instance-identifier $RDS_INSTANCE \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text)

        if [ "$RDS_STATUS" = "available" ]; then
            log_info "✓ RDS is available"
            break
        fi
        echo -n "."
        sleep 30
    done

    # 4. Ensure Vespa Docker container is running
    log_info "Checking Vespa container status..."
    if [ "$VESPA_ID" != "None" ] && [ -n "$VESPA_ID" ]; then
        # Wait for instance to be running
        aws ec2 wait instance-running \
            --region $REGION \
            --instance-ids $VESPA_ID

        # Start docker container via SSM
        log_info "Starting Vespa Docker container via SSM..."
        aws ssm send-command \
            --region $REGION \
            --instance-ids $VESPA_ID \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["docker start vespa || true"]' \
            --no-cli-pager > /dev/null
        sleep 5
        log_info "✓ Vespa container start command sent"
    fi

    # 5. Scale ECS back up
    log_info "Scaling ECS service to 1 task..."
    aws ecs update-service \
        --region $REGION \
        --cluster $CLUSTER \
        --service $SERVICE \
        --desired-count 1 \
        --no-cli-pager > /dev/null
    log_info "✓ ECS service scaling to 1"

    echo ""
    log_info "=========================================="
    log_info "Environment resuming!"
    log_info "=========================================="
    echo ""
    echo "The environment should be fully available in 5-10 minutes."
    echo ""
    echo "Monitor progress:"
    echo "  aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].{running: runningCount, desired: desiredCount}'"
    echo ""
    echo "Check site: https://demo.vigilon.app"
}

show_status() {
    echo "Current Environment Status:"
    echo "============================"
    echo ""

    # ECS
    ECS_COUNT=$(aws ecs describe-services \
        --region $REGION \
        --cluster $CLUSTER \
        --services $SERVICE \
        --query 'services[0].runningCount' \
        --output text 2>/dev/null || echo "error")
    echo "ECS Tasks Running: $ECS_COUNT"

    # RDS
    RDS_STATUS=$(aws rds describe-db-instances \
        --region $REGION \
        --db-instance-identifier $RDS_INSTANCE \
        --query 'DBInstances[0].DBInstanceStatus' \
        --output text 2>/dev/null || echo "not-found")
    echo "RDS Status: $RDS_STATUS"

    # Vespa
    VESPA_ID=$(get_vespa_instance_id)
    if [ "$VESPA_ID" != "None" ] && [ -n "$VESPA_ID" ]; then
        VESPA_STATE=$(aws ec2 describe-instances \
            --region $REGION \
            --instance-ids $VESPA_ID \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text)
        echo "Vespa EC2: $VESPA_STATE"
    else
        echo "Vespa EC2: not found"
    fi
    echo ""
}

# Main
case "${1:-}" in
    --resume|-r)
        resume_environment
        ;;
    --status|-s)
        show_status
        ;;
    --help|-h)
        echo "Usage: $0 [--resume|--status|--help]"
        echo ""
        echo "Options:"
        echo "  (no args)   Pause the environment (stop instances, scale to 0)"
        echo "  --resume    Resume the environment"
        echo "  --status    Show current status"
        echo "  --help      Show this help"
        ;;
    "")
        pause_environment
        ;;
    *)
        log_error "Unknown option: $1"
        echo "Use --help for usage"
        exit 1
        ;;
esac
