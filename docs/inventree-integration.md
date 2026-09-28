# InvenTree Inventory Integration

## Goal and Boundaries

Track physical inventory in InvenTree, deployed per environment as an application on an AWS Lightsail container service with an AWS Lightsail managed PostgreSQL database. The storefront and admin application continue to use the existing API Gateway and Python Lambda backend; browsers must not call InvenTree or receive its API credentials. Follow [Application architecture](application-architecture.md), [Backend API](backend-api.md), [Payment processing](payment-processing.md), [Infrastructure development workflow](infrastructure-development.md), and [Terraform conventions](terraform-conventions.md).

InvenTree owns physical stock, locations, stock adjustments, and the component/kit bill of materials. DynamoDB remains the order and checkout reservation store: its available-to-sell projection and atomic reservation guard must be derived from InvenTree stock, with outstanding reservations accounted for. Do not maintain an independently editable physical quantity in both systems. Product descriptions, prices, and sellability remain in the existing catalog data; map each sellable SKU and kit component to stable InvenTree part identifiers. Never infer an InvenTree part from a display name.

## Deployment Prerequisites

**InvenTree assumptions (stable docker docs):**

- **Lightsail VM** (Ubuntu) for:
  - InvenTree web app (Gunicorn)
  - Celery worker + Celery beat
  - Redis (broker + cache)
  - Nginx reverse proxy
- **Lightsail Managed PostgreSQL** (v15 recommended)
- **AWS S3** for persistent media/static files
- **Route 53** for DNS
- **Terraform** for reproducible infrastructure

## 2. Terraform: Infrastructure Layout

Create a new directory, e.g. `inventree-aws/`, and inside it:

### 2.1 `providers.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    lightsail = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2" # adjust as needed
}
```

### 2.2 variables.tf

```hcl
variable "project_name" {
  type    = string
  default = "inventree"
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "domain_name" {
  type = string
  # e.g. "inventory.example.com"
}

variable "db_master_password" {
  type      = string
  sensitive = true
}

variable "db_master_user" {
  type    = string
  default = "inventree"
}

variable "s3_bucket_name" {
  type = string
  # e.g. "inventree-media-example"
}
```

### main.tf — Lightsail VM + Managed PostgreSQL + S3
```hcl
locals {
  instance_name = "${var.project_name}-app"
  db_name       = "${var.project_name}-db"
}

# Lightsail instance (Ubuntu)
resource "aws_lightsail_instance" "app" {
  name              = local.instance_name
  availability_zone = "${var.aws_region}a"
  blueprint_id      = "ubuntu_22_04"
  bundle_id         = "medium_2_0" # adjust: small_2_0 for cheaper
  key_pair_name     = "your-keypair-name" # pre-created in Lightsail
}

# Static IP for the app
resource "aws_lightsail_static_ip" "app_ip" {
  name = "${local.instance_name}-ip"
}

resource "aws_lightsail_static_ip_attachment" "app_ip_attach" {
  static_ip_name = aws_lightsail_static_ip.app_ip.name
  instance_name  = aws_lightsail_instance.app.name
}

# Lightsail managed PostgreSQL
resource "aws_lightsail_database" "db" {
  name              = local.db_name
  availability_zone = "${var.aws_region}a"
  blueprint_id      = "postgresql_15" # PostgreSQL 15
  bundle_id         = "medium_2_0"
  master_database_name = "inventree"
  master_username      = var.db_master_user
  master_password      = var.db_master_password
  publicly_accessible  = true # or false + VPC peering if desired
}

# S3 bucket for media/static
resource "aws_s3_bucket" "media" {
  bucket = var.s3_bucket_name
}

resource "aws_s3_bucket_public_access_block" "media_block" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  block_public_policy     = true
  restrict_public_buckets = true
  ignore_public_acls      = true
}

# Route 53 record (assuming hosted zone already exists)
data "aws_route53_zone" "zone" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "app_record" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_lightsail_static_ip.app_ip.ip_address]
}
```
Apply with:

```bash
terraform init
terraform plan
terraform apply
```

### 3. Server Bootstrap (SSH + Base Setup)

Once Terraform finishes, SSH into the Lightsail instance:
```bash
ssh -i ~/.ssh/your-key.pem ubuntu@<STATIC_IP>
```

### 3.1 Install base packages
```bash
sudo apt update
sudo apt upgrade -y

sudo apt install -y \
  docker.io docker-compose-plugin \
  nginx \
  redis-server \
  python3-certbot-nginx
```

Enable Services:
```bash
sudo systemctl enable docker
sudo systemctl enable redis-server
sudo systemctl start docker
sudo systemctl start redis-server
```
### 4. Docker Compose for InvenTree (App + Celery)
Create a directory for the app:
```bash
sudo mkdir -p /opt/inventree
sudo chown ubuntu:ubuntu /opt/inventree
cd /opt/inventree
```

Create docker-compose.yml:
```yaml
version: "3.8"

services:
  inventree-web:
    image: ghcr.io/inventree/inventree:stable
    restart: always
    depends_on:
      - redis
    ports:
      - "8000:8000"
    environment:
      - INVENTREE_DB_ENGINE=postgresql
      - INVENTREE_DB_NAME=inventree
      - INVENTREE_DB_USER=${INVENTREE_DB_USER}
      - INVENTREE_DB_PASSWORD=${INVENTREE_DB_PASSWORD}
      - INVENTREE_DB_HOST=${INVENTREE_DB_HOST}
      - INVENTREE_DB_PORT=${INVENTREE_DB_PORT}
      - INVENTREE_REDIS_URL=redis://redis:6379
      - INVENTREE_MEDIA_ROOT=/media
      - INVENTREE_STATIC_ROOT=/static
      - INVENTREE_SECRET_KEY=${INVENTREE_SECRET_KEY}
      - INVENTREE_ALLOWED_HOSTS=${INVENTREE_ALLOWED_HOSTS}
      - INVENTREE_USE_S3=true
      - INVENTREE_S3_BUCKET=${INVENTREE_S3_BUCKET}
      - INVENTREE_S3_REGION=${INVENTREE_S3_REGION}
      - INVENTREE_S3_ACCESS_KEY=${INVENTREE_S3_ACCESS_KEY}
      - INVENTREE_S3_SECRET_KEY=${INVENTREE_S3_SECRET_KEY}
      - INVENTREE_S3_ENDPOINT_URL=https://s3.${INVENTREE_S3_REGION}.amazonaws.com
      - INVENTREE_DB_OPTIONS={"sslmode":"require"}
    volumes:
      - inventree-config:/home/inventree/.local/share/inventree
    command: >
      sh -c "
      python manage.py migrate &&
      python manage.py collectstatic --no-input &&
      gunicorn InvenTree.wsgi:application --bind 0.0.0.0:8000
      "

  inventree-worker:
    image: ghcr.io/inventree/inventree:stable
    restart: always
    depends_on:
      - redis
    environment:
      - INVENTREE_DB_ENGINE=postgresql
      - INVENTREE_DB_NAME=inventree
      - INVENTREE_DB_USER=${INVENTREE_DB_USER}
      - INVENTREE_DB_PASSWORD=${INVENTREE_DB_PASSWORD}
      - INVENTREE_DB_HOST=${INVENTREE_DB_HOST}
      - INVENTREE_DB_PORT=${INVENTREE_DB_PORT}
      - INVENTREE_REDIS_URL=redis://redis:6379
      - INVENTREE_MEDIA_ROOT=/media
      - INVENTREE_STATIC_ROOT=/static
      - INVENTREE_SECRET_KEY=${INVENTREE_SECRET_KEY}
      - INVENTREE_ALLOWED_HOSTS=${INVENTREE_ALLOWED_HOSTS}
      - INVENTREE_USE_S3=true
      - INVENTREE_S3_BUCKET=${INVENTREE_S3_BUCKET}
      - INVENTREE_S3_REGION=${INVENTREE_S3_REGION}
      - INVENTREE_S3_ACCESS_KEY=${INVENTREE_S3_ACCESS_KEY}
      - INVENTREE_S3_SECRET_KEY=${INVENTREE_S3_SECRET_KEY}
      - INVENTREE_S3_ENDPOINT_URL=https://s3.${INVENTREE_S3_REGION}.amazonaws.com
      - INVENTREE_DB_OPTIONS={"sslmode":"require"}
    volumes:
      - inventree-config:/home/inventree/.local/share/inventree
    command: >
      sh -c "
      celery -A InvenTree worker -l info
      "

  inventree-beat:
    image: ghcr.io/inventree/inventree:stable
    restart: always
    depends_on:
      - redis
    environment:
      - INVENTREE_DB_ENGINE=postgresql
      - INVENTREE_DB_NAME=inventree
      - INVENTREE_DB_USER=${INVENTREE_DB_USER}
      - INVENTREE_DB_PASSWORD=${INVENTREE_DB_PASSWORD}
      - INVENTREE_DB_HOST=${INVENTREE_DB_HOST}
      - INVENTREE_DB_PORT=${INVENTREE_DB_PORT}
      - INVENTREE_REDIS_URL=redis://redis:6379
      - INVENTREE_SECRET_KEY=${INVENTREE_SECRET_KEY}
      - INVENTREE_ALLOWED_HOSTS=${INVENTREE_ALLOWED_HOSTS}
      - INVENTREE_DB_OPTIONS={"sslmode":"require"}
    volumes:
      - inventree-config:/home/inventree/.local/share/inventree
    command: >
      sh -c "
      celery -A InvenTree beat -l info
      "

  redis:
    image: redis:alpine
    restart: always

volumes:
  inventree-config:
```
This layout follows the InvenTree Docker guidance: web container plus linked services (DB, Redis, external storage).

### 4.1 Environment file
Create .env in /opt/inventree:
```bash
cat > .env << 'EOF'
INVENTREE_DB_USER=inventree
INVENTREE_DB_PASSWORD=<lightsail-db-password>
INVENTREE_DB_HOST=<lightsail-db-endpoint-host>
INVENTREE_DB_PORT=5432

INVENTREE_SECRET_KEY=<long-random-string>
INVENTREE_ALLOWED_HOSTS=<your-domain-name>

INVENTREE_S3_BUCKET=<your-s3-bucket-name>
INVENTREE_S3_REGION=us-west-2
INVENTREE_S3_ACCESS_KEY=<iam-access-key>
INVENTREE_S3_SECRET_KEY=<iam-secret-key>
EOF
```
Use an IAM user or role with restricted access to the S3 bucket.

Run:
```bash
docker compose --env-file .env up -d
```

### 5. Nginx Reverse Proxy + TLS
Create /etc/nginx/sites-available/inventree:
```nginx
server {
    listen 80;
    server_name INVENTREE_DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
Enable Site:
```bash
sudo ln -s /etc/nginx/sites-available/inventree /etc/nginx/sites-enabled/inventree
sudo nginx -t
sudo systemctl restart nginx
```

### 5.2 Let’s Encrypt TLS
```bash
sudo certbot --nginx -d INVENTREE_DOMAIN
```
Certbot will update the Nginx config to use HTTPS.

### 6. Database TLS Configuration
Lightsail managed PostgreSQL supports TLS by default. InvenTree/Django uses sslmode=require via DB options.

You already set:
```yaml
- INVENTREE_DB_OPTIONS={"sslmode":"require"}
```
If you need CA verification, download the AWS RDS/Lightsail CA bundle and mount it into the container, then extend DB_OPTIONS with sslrootcert=/path/to/ca.pem.

### 7. Initial Application Setup

### 7.1 Create superuser (optional via CLI)
```bash
docker compose --env-file .env exec inventree-web python manage.py createsuperuser
```
Or use the web UI:

- Browse to https://INVENTREE_DOMAIN/
- Follow the initial setup wizard.

### 8. Backups and Maintenance
Database:
- Lightsail managed PostgreSQL:
    - Enable automatic backups in the Lightsail console.
    - Consider manual snapshots before major upgrades.
- App & Config:
    - /opt/inventree:
        - Keep docker-compose.yml and .env in Git (without secrets).
        - Store secrets in a separate .env.local or use SSM Parameter Store if you later move to EC2.
- S3:
    - Enable bucket versioning and lifecycle rules if desired.
- OS & Packages:
```bash
sudo apt update
sudo apt upgrade -y
```

### 9. Cost-Control Notes
- Use smaller Lightsail bundles (small_2_0 or nano_2_0) if load is light.
- Keep Redis on the same VM to avoid extra services.
- Avoid Lightsail Container Service for InvenTree—multi-process and persistent storage requirements are not met there.
- Consider CloudFront later only if you need global caching.

### 10. VSCode Usage Pattern
```text
inventree-aws/
  instruction.md        # this file
  terraform/
    providers.tf
    variables.tf
    main.tf
  server/
    docker-compose.yml
    .env.example
    nginx-inventree.conf
```
Workflow in VSCode:
1. Open inventree-aws/ folder.
2. Use integrated terminal for terraform init/plan/apply.
3. Use SSH extension to connect to Lightsail instance.
4. Edit docker-compose.yml, .env, and Nginx config directly from VSCode.
5. Commit changes so the runbook stays in sync with reality.

### 11. Next Iterations
Once this baseline is running, you can:
- Add health checks and monitoring (Prometheus, CloudWatch agent).
- Introduce staging vs production environments via Terraform workspaces.
- Harden IAM for S3 and DB access.
- Optionally migrate to EC2 + RDS + ElastiCache if scale demands it.

## Provision Dev and Prod Environments
Provision separate dev and prod resources in `us-west-2`, starting with `infra/dev` and promoting the reviewed configuration to `infra/prod`. Add reusable Terraform modules under `infra/modules` following the established naming, tagging, inputs, and outputs conventions. Provision at least:

- A Lightsail container service for the InvenTree application, with pinned image versions, an explicit public web endpoint, health checks, and enough capacity for the verified web/worker topology. Build and publish the image through environment-specific deployment automation in `scripts`; do not depend on mutable `latest` tags.
- A Lightsail managed PostgreSQL database for each environment, private/restricted access where supported, TLS enforced by the application connection, backups enabled, and restore procedure tested. Never allow the database to be a public admin endpoint merely to make container connectivity work.
- Durable media storage and a supported broker/cache for the chosen InvenTree release; configure them separately from container-local disk. Restrict access to the application and integration components. Persist data across container revisions and restarts.
- Environment-scoped secrets for database credentials, InvenTree's application secret, and integration API credentials in an approved secret store. Inject them at deployment time without printing them in plans, logs, scripts, or committed files. Confirm the actual Lightsail secret-delivery mechanism before wiring it; do not place plaintext credentials in Terraform state or container deployment definitions.

## InvenTree Endpoints
- HTTPS for the application hostname and outbound HTTPS access for backend integration. Protect the InvenTree UI with its own role-based access; a Cognito JWT for the storefront/admin API is not itself an InvenTree login. Restrict the public surface and document any unavoidable public API endpoint, rate limits, and credential rotation.

Keep InvenTree operational endpoints out of the storefront's public configuration. If the Lambda backend cannot connect securely to the Lightsail service using a supported route, document the integration path and obtain approval before expanding public ingress. Do not apply infrastructure changes or mutate AWS resources without an explicit operator request.

## Data and Integration Contract

Implement the InvenTree client in `backend/shared` so checkout, admin, and reconciliation use one authenticated, timeout-bounded integration. Give the service account only the InvenTree permissions required for reads and stock movements. Use the API of the pinned InvenTree release, verified against that release's documentation or schema; do not assume endpoint names, payloads, or reservation semantics. Keep API tokens server-side. Make retries bounded and safe for non-idempotent requests.

Maintain a SKU-to-part mapping with explicit unit of measure and kit BOM interpretation. Decide whether sellable stock is finished kits, components, or both, and prevent the same components from being counted twice. Define which locations and stock states contribute to sellable quantity, and exclude quarantined, damaged, or otherwise unavailable stock. Validate missing mappings, disabled parts, unexpected units, and insufficient stock as explicit errors rather than treating them as zero or silently selling from a different part.

The existing checkout path reserves inventory transactionally in DynamoDB (see [Payment processing](payment-processing.md)). Preserve that atomic guard while integrating InvenTree:

1. Sync InvenTree's eligible physical quantities and BOM-derived availability into a versioned DynamoDB sellable-stock projection. A sync must not overwrite outstanding checkout reservations; compute availability from the latest physical stock minus active reservations, or use an equivalent atomic ledger that preserves both values. Record the part mapping, source revision/time, and last successful sync.
2. At checkout, reject stale or missing projections according to an explicit freshness limit; use a conditional DynamoDB transaction to reserve stock and create the pending order. For component-based kits, reserve every required component atomically. Never trust client-submitted quantities, prices, or stock counts.
3. On verified payment confirmation, perform the corresponding InvenTree stock allocation/movement through an idempotent, durable integration job keyed by the order and line item. Once the movement is confirmed, retire that order's active reservation exactly once as the reduced physical stock enters the projection; avoid counting both the movement and the reservation against availability. Mark the inventory-sync state separately from the payment state; payment webhooks alone must not claim that physical stock was updated. Retry failures without duplicating movements, surface unresolved failures to operators, and reconcile back to InvenTree.
4. On cancellation, payment failure, reservation expiry, or refund/return according to the business policy, release the DynamoDB reservation exactly once. Reverse or adjust an InvenTree movement only when one actually occurred, using a separately idempotent operation. Do not silently restock shipped goods on a refund.

The resulting order may be `paid` while stock posting is pending; fulfillment must be blocked until the required inventory movement succeeds or an operator resolves it. Document and test how a partial failure between the order transaction, provider request, webhook, stock movement, and reservation release is retried. Do not make a distributed transaction claim across DynamoDB, payment providers, and InvenTree.

Admin stock changes should go through authorized backend operations using InvenTree as the physical-stock writer. Require the existing `Admins` Cognito group check in each admin handler. Do not expose a generic InvenTree API proxy or allow an admin form to directly set the DynamoDB projection. Audit actor, part, location, quantity, reason, and resulting stock movement; reconcile the projection after each change. Catalog browsing should use the backend's projection, not call InvenTree on every request.

## Reconciliation and Operations

Run an environment-specific scheduled reconciliation that compares InvenTree eligible physical stock and mapped BOM availability with the DynamoDB projection, active reservations, completed orders, and pending inventory jobs. Repair only well-defined projection drift automatically; report unknown mappings, duplicate movements, negative availability, stale syncs, and failed jobs for human review. Record last-success timestamps and alert on integration failures or an aging projection. Do not log customer data, API tokens, or database passwords.

Back up the Lightsail database and durable media together under an explicit retention policy, and test a restore into an isolated environment. Pin and stage InvenTree upgrades in dev, run the supported database migration procedure against a backed-up database, then promote after checking API compatibility and worker processing. Roll back application image revisions only when the migrated schema is compatible; otherwise use the tested restore plan. Document credential rotation, health checks, alerts, and the on-call recovery steps before production use.

## Implementation and Verification Checklist

1. Verify the supported InvenTree/Lightsail topology and write down the deployment decisions above, including the broker, media, secure database connectivity, and secret injection. Resolve any unsupported requirement before coding dependent infrastructure.
2. Build the dev Lightsail and supporting resources, application packaging, and explicit dev deployment script. Run Terraform format/validation and review the dev plan for exposure, replacement, and credential leaks before any operator-authorized apply.
3. Add the server-side client, SKU/part mapping, sync and reservation ledger, idempotent stock-posting jobs, admin writes, and reconciliation. Update [Backend API](backend-api.md), [Payment processing](payment-processing.md), and the DynamoDB data-model documentation when the implementation changes their contracts.
4. Test component and finished-kit stock without double counting, last-unit concurrent checkout, stale sync rejection, InvenTree downtime, failed provider checkout, duplicate/out-of-order webhooks, cancellation after payment, retry after partial movement, and reconciliation after an admin adjustment.
5. Validate a dev deployment end to end: health check, HTTPS, database migrations, persistent media, worker processing, stock update to catalog, checkout to InvenTree movement, cancellation/release, alerts, and restore. Promote the reviewed equivalent to prod only through [Infrastructure development workflow](infrastructure-development.md).

Never use production inventory or credentials to validate a dev deployment.