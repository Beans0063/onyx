# Onyx AWS Deployment Plan

## Executive Summary

This document outlines a HIPAA-compliant, cost-optimized AWS deployment strategy for Onyx using ECS Fargate and Terraform. The architecture supports multi-tenant deployments with shared infrastructure where safe, and isolated resources where required.

**Key Decisions:**
- **Compute**: ECS Fargate (not EKS) - simpler, lower operational overhead
- **Database**: Shared RDS PostgreSQL with separate databases per tenant
- **Search**: Shared Vespa on EC2 with tenant namespaces (required - only supported vector DB)
- **Embeddings**: Cloud API (OpenAI/Cohere) - no self-hosted model servers needed
- **Storage**: Shared S3 bucket with tenant prefixes
- **Networking**: Single VPC, shared ALB with host-based routing

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                    INTERNET                                      │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              AWS WAF (HIPAA)                                     │
│                    Rate limiting, SQL injection, XSS protection                  │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     Application Load Balancer (HTTPS/443)                        │
│                         Host-based routing per tenant                            │
│                     tenant-a.example.com → Target Group A                        │
│                     tenant-b.example.com → Target Group B                        │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
┌─────────────────────────┐ ┌─────────────────────────┐ ┌─────────────────────────┐
│     ECS Service A       │ │     ECS Service B       │ │     ECS Service N       │
│  ┌───────────────────┐  │ │  ┌───────────────────┐  │ │  ┌───────────────────┐  │
│  │ web_server (3000) │  │ │  │ web_server (3000) │  │ │  │ web_server (3000) │  │
│  ├───────────────────┤  │ │  ├───────────────────┤  │ │  ├───────────────────┤  │
│  │ api_server (8080) │  │ │  │ api_server (8080) │  │ │  │ api_server (8080) │  │
│  ├───────────────────┤  │ │  ├───────────────────┤  │ │  ├───────────────────┤  │
│  │ background        │  │ │  │ background        │  │ │  │ background        │  │
│  └───────────────────┘  │ │  └───────────────────┘  │ │  └───────────────────┘  │
│     DB: onyx_tenant_a   │ │     DB: onyx_tenant_b   │ │     DB: onyx_tenant_n   │
└─────────────────────────┘ └─────────────────────────┘ └─────────────────────────┘
         │                           │                           │
         │    Embedding API Calls    │                           │
         └──────────────┬────────────┴───────────────────────────┘
                        │
                        ▼
         ┌──────────────────────────────┐
         │  Cloud Embedding Provider    │
         │  (OpenAI / Cohere / Google)  │
         │  • No infrastructure needed  │
         │  • Pay-per-use pricing       │
         │  • HIPAA BAA available       │
         └──────────────────────────────┘

┌───────────────────────────────────────────────────────────────────────────────────┐
│                           SHARED SERVICES (Private Subnets)                       │
│                                                                                   │
│  ┌─────────────────────┐  ┌─────────────────────────┐  ┌───────────────────────┐ │
│  │ Vespa (EC2)         │  │ RDS PostgreSQL          │  │ ElastiCache Redis     │ │
│  │ • Search index      │  │ • Multi-DB per tenant   │  │ • Session cache       │ │
│  │ • Tenant namespaces │  │ • Encrypted at rest     │  │ • Shared across all   │ │
│  │ • REQUIRED          │  │ • HIPAA compliant       │  │                       │ │
│  └─────────────────────┘  └─────────────────────────┘  └───────────────────────┘ │
│                                                                                   │
│  ┌─────────────────────┐                                                         │
│  │ S3 Bucket           │                                                         │
│  │ • /tenant-a/files   │                                                         │
│  │ • /tenant-b/files   │                                                         │
│  │ • Encrypted (SSE)   │                                                         │
│  └─────────────────────┘                                                         │
└───────────────────────────────────────────────────────────────────────────────────┘
```

---

## Cloud Embedding Provider Options

Onyx supports multiple cloud embedding providers. Configure via Admin UI after deployment.

| Provider | Model | Cost/1M tokens | HIPAA BAA | Recommendation |
|----------|-------|----------------|-----------|----------------|
| **OpenAI** | text-embedding-3-small | $0.02 | Enterprise plan | Best balance of cost/quality |
| **OpenAI** | text-embedding-3-large | $0.13 | Enterprise plan | Higher quality, higher cost |
| **Cohere** | embed-english-v3.0 | $0.10 | Enterprise | Good for English-only |
| **Google** | text-embedding-005 | $0.025 | Via Vertex AI | Good GCP integration |
| **Voyage** | voyage-large-2-instruct | $0.02 | Contact sales | Optimized for RAG |

**For HIPAA compliance**: Ensure you have a BAA with your chosen embedding provider.

### Estimated Embedding Costs by Usage

| Usage Level | Documents/Month | Est. Tokens | OpenAI Cost |
|-------------|-----------------|-------------|-------------|
| Light Demo | 1,000 docs | ~5M tokens | ~$0.10/mo |
| Medium Demo | 10,000 docs | ~50M tokens | ~$1/mo |
| Production | 100,000 docs | ~500M tokens | ~$10/mo |

---

## Resource Allocation Strategy

### Shared Resources (Cost Optimized)

| Resource | Demo Sizing | Production Sizing | Notes |
|----------|-------------|-------------------|-------|
| **RDS PostgreSQL** | db.t4g.micro (2 vCPU, 1GB) | db.r6g.large (2 vCPU, 16GB) | Multi-AZ for prod |
| **ElastiCache Redis** | cache.t4g.micro | cache.r6g.large | Cluster mode for prod |
| **Vespa EC2** | t3.medium (2 vCPU, 4GB) | r6i.xlarge (4 vCPU, 32GB) | Required - only vector DB |
| **NAT Gateway** | 1 (single AZ) | 3 (multi-AZ) | High availability for prod |
| **ALB** | 1 shared | 1 shared | WAF attached |

### Per-Tenant Resources

| Resource | Demo Sizing | Production Sizing | Notes |
|----------|-------------|-------------------|-------|
| **ECS Task** | 0.5 vCPU, 1GB | 2 vCPU, 4GB | web + api + background |
| **CloudWatch Logs** | 30 day retention | 365 day retention | HIPAA audit trail |
| **S3 Prefix** | Shared bucket | Shared bucket | Isolated by path |
| **PostgreSQL DB** | Shared instance | Shared instance | Separate database |

---

## Estimated Monthly Costs

### Demo Environment (1-5 Tenants)

| Service | Specification | Est. Cost/Month |
|---------|---------------|-----------------|
| RDS PostgreSQL | db.t4g.micro, 20GB | $15 |
| ElastiCache Redis | cache.t4g.micro | $12 |
| Vespa EC2 | t3.medium, 50GB EBS | $35 |
| ECS Fargate (per tenant x5) | 5 tasks, 0.5vCPU/1GB each | $75 |
| ALB | 1 ALB + data transfer | $25 |
| NAT Gateway | 1 gateway | $35 |
| S3 | 50GB storage | $2 |
| CloudWatch Logs | 10GB/month | $5 |
| **Cloud Embeddings** | OpenAI (light usage) | **~$1** |
| **Total Demo** | | **~$205/month** |

**Savings vs self-hosted model servers: $60/month (23% reduction)**

### Production Environment (10-25 Tenants)

| Service | Specification | Est. Cost/Month |
|---------|---------------|-----------------|
| RDS PostgreSQL | db.r6g.large, Multi-AZ, 200GB | $350 |
| ElastiCache Redis | cache.r6g.large, Multi-AZ | $200 |
| Vespa EC2 | r6i.xlarge, 200GB EBS | $200 |
| ECS Fargate (per tenant x25) | 25 tasks, 2vCPU/4GB each | $1,500 |
| ALB + WAF | 1 ALB + WAF rules | $75 |
| NAT Gateway | 3 gateways (multi-AZ) | $105 |
| S3 | 500GB storage | $15 |
| CloudWatch Logs | 100GB/month | $50 |
| KMS | Encryption keys | $5 |
| **Cloud Embeddings** | OpenAI (production usage) | **~$25** |
| **Total Production** | | **~$2,525/month** |

**Savings vs self-hosted model servers: $225/month (8% reduction)**

---

## HIPAA Compliance Checklist

### 1. Business Associate Agreement (BAA)
- [ ] Sign AWS BAA (free, via AWS Artifact)
- [ ] Sign BAA with embedding provider (OpenAI Enterprise, Cohere Enterprise, etc.)
- [ ] Enable HIPAA-eligible services only

### 2. Encryption

**At Rest:**
- [x] RDS: `storage_encrypted = true` (already configured)
- [ ] S3: Enable default encryption (SSE-S3 or SSE-KMS)
- [ ] EBS: Enable encryption for Vespa EC2 volumes
- [ ] ElastiCache: Enable at-rest encryption

**In Transit:**
- [ ] ALB: HTTPS only (ACM certificate)
- [ ] RDS: `require_ssl = true` via parameter group
- [ ] ElastiCache: `transit_encryption_enabled = true`
- [ ] Vespa: TLS between ECS and EC2
- [x] Embedding API: HTTPS by default

### 3. Access Controls
- [ ] IAM: Least privilege policies for ECS tasks
- [ ] VPC: Private subnets for all data services
- [ ] Security Groups: Explicit allow rules only
- [ ] Secrets Manager: Store database credentials and API keys
- [ ] MFA: Enforce for AWS console access

### 4. Audit Logging
- [ ] CloudTrail: Enable for all API calls
- [ ] VPC Flow Logs: Enable for network traffic
- [ ] RDS Audit Logs: Enable via parameter group
- [ ] CloudWatch Logs: Retain for 365 days (production)
- [ ] S3 Access Logs: Enable for audit bucket

### 5. Network Security
- [ ] WAF: SQL injection, XSS, rate limiting rules
- [ ] VPC: No public IPs on data services
- [ ] NACLs: Restrict traffic between subnets
- [ ] Security Groups: Only necessary ports open

---

## Terraform Module Structure

```
deployment/terraform/
├── modules/
│   └── aws/
│       ├── vpc/                    # VPC with public/private subnets
│       ├── postgres/               # RDS PostgreSQL (shared)
│       ├── redis/                  # ElastiCache Redis (shared)
│       ├── s3/                     # S3 bucket (shared)
│       ├── vespa/                  # Vespa EC2 instance (shared) [NEW]
│       ├── waf/                    # WAF rules (HIPAA) [EXISTS]
│       ├── secrets/                # Secrets Manager [NEW]
│       ├── logging/                # CloudTrail, VPC Flow Logs [NEW]
│       └── onyx_tenant/            # Per-tenant ECS service [UPDATE]
│
└── live/
    └── aws/
        ├── shared/                 # Shared infrastructure
        │   └── main.tf
        ├── demo/                   # Demo environment tenants
        │   ├── main.tf
        │   └── tenants.tf          # Tenant definitions
        └── prod/                   # Production tenants
            ├── main.tf
            └── tenants.tf
```

---

## Tenant Configuration Pattern

### Adding a New Tenant

```hcl
# live/aws/demo/tenants.tf

locals {
  tenants = {
    "acme-corp" = {
      domain      = "acme.demo.example.com"
      cpu         = 512   # 0.5 vCPU (demo)
      memory      = 1024  # 1 GB (demo)
      auth_type   = "basic"
    }
    "beta-inc" = {
      domain      = "beta.demo.example.com"
      cpu         = 512
      memory      = 1024
      auth_type   = "oidc"
      oidc_issuer = "https://login.beta-inc.com"
    }
    "gamma-llc" = {
      domain      = "gamma.demo.example.com"
      cpu         = 512
      memory      = 1024
      auth_type   = "basic"
    }
  }
}

module "tenant" {
  source   = "../../../modules/aws/onyx_tenant"
  for_each = local.tenants

  tenant_name = each.key
  environment = "demo"

  # Shared infrastructure
  vpc_id              = module.shared.vpc_id
  private_subnet_ids  = module.shared.private_subnets
  ecs_cluster_id      = module.shared.ecs_cluster_id
  alb_listener_arn    = module.shared.alb_https_listener_arn
  alb_security_group_id = module.shared.alb_sg_id

  # Tenant-specific
  domain_name      = each.value.domain
  alb_dns_name     = each.value.domain
  auth_type        = each.value.auth_type
  container_cpu    = each.value.cpu
  container_memory = each.value.memory

  # Shared services
  postgres_host     = module.shared.postgres_endpoint
  postgres_user     = "onyx_admin"
  postgres_password = data.aws_secretsmanager_secret_version.postgres.secret_string
  postgres_db       = "onyx_${replace(each.key, "-", "_")}"

  vespa_host = module.shared.vespa_private_ip
  redis_host = module.shared.redis_endpoint

  # S3 with tenant prefix
  s3_bucket = module.shared.s3_bucket_name
  s3_prefix = each.key

  # Cloud embeddings - configured via Onyx Admin UI after deployment
  # No model server configuration needed!
}
```

---

## Post-Deployment: Configure Cloud Embeddings

After deploying a tenant, configure the embedding provider via the Onyx Admin UI:

1. **Login** to the Onyx admin panel at `https://<tenant-domain>/admin`
2. **Navigate** to Admin → Search Settings → Embedding Model
3. **Select provider**: OpenAI, Cohere, Google, or Voyage
4. **Enter API key**: Store in Secrets Manager, reference via environment variable
5. **Choose model**: e.g., `text-embedding-3-small` for OpenAI
6. **Save and re-index**: Onyx will automatically re-index documents with new embeddings

### Storing Embedding API Keys Securely

```hcl
# In secrets module
resource "aws_secretsmanager_secret" "openai_api_key" {
  name = "${var.environment}/openai-api-key"
}

resource "aws_secretsmanager_secret_version" "openai_api_key" {
  secret_id     = aws_secretsmanager_secret.openai_api_key.id
  secret_string = var.openai_api_key  # Pass via TF_VAR or tfvars
}

# Reference in ECS task definition (optional - can also configure via UI)
environment = [
  {
    name  = "OPENAI_API_KEY"
    value = data.aws_secretsmanager_secret_version.openai_api_key.secret_string
  }
]
```

---

## Scaling from Demo to Production

### Step 1: Update Shared Infrastructure

```hcl
# Change instance sizes in shared module
variable "environment" {
  default = "prod"  # was "demo"
}

locals {
  sizing = {
    demo = {
      rds_instance    = "db.t4g.micro"
      redis_instance  = "cache.t4g.micro"
      vespa_instance  = "t3.medium"
    }
    prod = {
      rds_instance    = "db.r6g.large"
      redis_instance  = "cache.r6g.large"
      vespa_instance  = "r6i.xlarge"
    }
  }
}
```

### Step 2: Enable Multi-AZ

```hcl
# RDS
multi_az = var.environment == "prod" ? true : false

# NAT Gateways
single_nat_gateway = var.environment == "prod" ? false : true
```

### Step 3: Enable Production Security

```hcl
# Enable WAF
enable_waf = var.environment == "prod" ? true : false

# Enable RDS deletion protection
deletion_protection = var.environment == "prod" ? true : false

# Enable enhanced monitoring
performance_insights_enabled = var.environment == "prod" ? true : false
```

### Step 4: Update Tenant Resources

```hcl
# Per-tenant sizing
locals {
  tenant_sizing = {
    demo = { cpu = 512, memory = 1024 }
    prod = { cpu = 2048, memory = 4096 }
  }
}
```

---

## Implementation Phases

### Phase 1: Foundation
1. Create secrets module (Secrets Manager for credentials + API keys)
2. Create logging module (CloudTrail, VPC Flow Logs)
3. Update VPC module for HIPAA (flow logs, NACLs)
4. Update Vespa module (EBS encryption, security)
5. **Remove model server containers from tenant module**

### Phase 2: HIPAA Hardening
1. Enable RDS encryption and SSL enforcement
2. Configure WAF with HIPAA rules
3. Enable S3 encryption and access logging
4. Configure ElastiCache encryption
5. Set up CloudWatch log retention policies
6. Sign BAA with embedding provider

### Phase 3: Multi-Tenant Refinement
1. Update tenant module (simplified - no model servers)
2. Implement S3 prefix isolation per tenant
3. Add tenant database creation automation
4. Create Vespa namespace configuration
5. Add HTTPS listener with ACM certificate

### Phase 4: Operations
1. Create tenant onboarding automation
2. Set up monitoring and alerting
3. Document runbooks (including embedding provider setup)
4. Create backup/restore procedures
5. Load testing and optimization

---

## Key Changes from Current State

| Current | Proposed | Rationale |
|---------|----------|-----------|
| Model servers per tenant | Cloud embedding API | Saves $60/mo, no infrastructure to manage |
| 5 containers per tenant | 3 containers per tenant | Simpler, lower cost |
| Hardcoded passwords | Secrets Manager | HIPAA requirement |
| HTTP ALB listener | HTTPS with ACM | HIPAA encryption in transit |
| No WAF | WAF enabled | HIPAA security controls |
| Single AZ (demo) | Multi-AZ (prod) | High availability |
| No audit logging | Full audit trail | HIPAA requirement |
| 30-day log retention | 365-day retention (prod) | HIPAA requirement |

---

## Switching Embedding Providers Later

One advantage of cloud embeddings: **easy to switch providers**.

1. Go to Admin → Search Settings
2. Select new provider and enter API key
3. Click "Re-index all documents"
4. Onyx handles the migration automatically

No infrastructure changes needed!

---

## Open Questions for Further Discussion

1. **Embedding Provider Choice**: OpenAI is recommended for best cost/quality balance. Do you have a preference or existing relationship with another provider?

2. **HIPAA BAA**: Do you already have an OpenAI Enterprise account with BAA, or should we plan for Cohere/Google instead?

3. **Custom Domain Timing**: When do you plan to set up custom domains (e.g., tenant.yourcompany.com)?

4. **SSO/Authentication**: Will tenants use their own identity providers (OIDC/SAML)?

5. **Backup Strategy**: What's the required RPO/RTO for data recovery?

6. **Monitoring**: Any existing observability stack (Datadog, New Relic) to integrate?

7. **CI/CD**: How will tenant deployments be automated (GitHub Actions, etc.)?
