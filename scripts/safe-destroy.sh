#!/bin/bash
# Safe Destroy - Creates backups before terraform destroy
# Usage: ./scripts/safe-destroy.sh

set -e

REGION="us-west-2"
RDS_INSTANCE="onyx-prod-postgres"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=========================================="
echo "Safe Destroy - Backup Before Terraform Destroy"
echo "=========================================="
echo ""

# 1. Create RDS Snapshot
log_info "Creating RDS snapshot..."
SNAPSHOT_ID="onyx-backup-${TIMESTAMP}"

aws rds create-db-snapshot \
    --region $REGION \
    --db-instance-identifier $RDS_INSTANCE \
    --db-snapshot-identifier $SNAPSHOT_ID \
    --no-cli-pager

log_info "Snapshot initiated: $SNAPSHOT_ID"
log_info "Waiting for snapshot to complete (this may take 5-15 minutes)..."

aws rds wait db-snapshot-available \
    --region $REGION \
    --db-snapshot-identifier $SNAPSHOT_ID

log_info "✓ RDS snapshot complete: $SNAPSHOT_ID"

# 2. Backup S3 bucket
log_info "Finding S3 bucket..."
S3_BUCKET=$(aws s3 ls | grep onyx-prod-file-store | awk '{print $3}')

if [ -n "$S3_BUCKET" ]; then
    BACKUP_BUCKET="onyx-backups-${TIMESTAMP}"
    log_info "Creating backup bucket: $BACKUP_BUCKET"
    aws s3 mb "s3://$BACKUP_BUCKET" --region $REGION

    log_info "Copying files from $S3_BUCKET to $BACKUP_BUCKET..."
    aws s3 sync "s3://$S3_BUCKET" "s3://$BACKUP_BUCKET" --region $REGION
    log_info "✓ S3 backup complete"
else
    log_warn "No S3 bucket found matching 'onyx-prod-file-store'"
fi

# 3. Note about Vespa
echo ""
log_warn "=========================================="
log_warn "IMPORTANT: Vespa vector data CANNOT be backed up easily"
log_warn "After restore, you will need to re-index all documents"
log_warn "=========================================="

# 4. Save current ALB DNS for reference
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --region $REGION \
    --names onyx-prod-alb \
    --query 'LoadBalancers[0].DNSName' \
    --output text 2>/dev/null || echo "not-found")

echo ""
echo "=========================================="
echo "Backup Summary"
echo "=========================================="
echo ""
echo "RDS Snapshot:    $SNAPSHOT_ID"
echo "S3 Backup:       ${BACKUP_BUCKET:-'N/A'}"
echo "Current ALB DNS: $ALB_DNS"
echo ""
echo "These resources are preserved and will NOT be deleted by terraform destroy:"
echo "  - RDS Snapshot: $SNAPSHOT_ID"
echo "  - S3 Backup Bucket: ${BACKUP_BUCKET:-'N/A'}"
echo ""
echo "To restore from snapshot after terraform apply:"
echo "  1. Update terraform to use snapshot: db_snapshot_identifier = \"$SNAPSHOT_ID\""
echo "  2. Or manually restore: aws rds restore-db-instance-from-db-snapshot"
echo ""
echo "To restore S3 files after terraform apply:"
echo "  aws s3 sync s3://$BACKUP_BUCKET s3://<new-bucket-name>"
echo ""
log_warn "Remember: After terraform apply, update DNS for demo.vigilon.app"
echo ""
read -p "Ready to run 'terraform destroy'? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cd deployment/terraform/live/aws/prod
    terraform destroy
else
    log_info "Aborted. Backups have been created but destroy was not run."
fi
