# Website and InvenTree Delivery Plan

## Purpose

Use this document as the implementation sequence and release checklist for delivering the customer storefront, admin application, API, payment flow, and InvenTree inventory integration. It consolidates the boundaries in [Application architecture](application-architecture.md), [Frontend applications](frontend-applications.md), [Backend API](backend-api.md), [Cognito authentication](cognito-authentication.md), [Payment processing](payment-processing.md), [InvenTree integration](inventree-integration.md), [Infrastructure development workflow](infrastructure-development.md), and [Terraform conventions](terraform-conventions.md).

## Verified Starting Point

As of 2026-09-28 the repository contains only `AGENTS.md`, `README.md` (the planned InvenTree staff-access runbook), `LICENSE`, `.gitignore`, and design documents under `docs/`. Those documents include the [DynamoDB data model](dynamodb-data-model.md) and the [Architecture decision register](architecture-decisions.md).

There is no `infra/`, `backend/`, `frontend/`, `admin/`, `scripts/`, or CI workflow. No AWS resource described in these guides has been verified as deployed. Treat every path, module, route, and resource here as proposed design, and confirm the live repository and AWS state before making implementation or deployment assumptions.

## Target Architecture

- **Storefront:** `frontend/`, a responsive React + Vite static application. Public catalog browsing does not require login; cart, checkout, and order history use the signed-in customer's Cognito session.
- **Admin:** `admin/`, a separately built and deployed React + Vite static application. It uses its own Cognito app client. All privileged operations are authorized in the backend, not merely hidden in the UI.
- **Static delivery:** separate private S3 buckets and CloudFront distributions for storefront and admin. CloudFront is the public delivery layer; use the SPA fallback from the planned `static-site` module and do not expose S3 origins directly.
- **API:** API Gateway HTTP API invoking domain-specific Python Lambdas in `backend/`. Public catalog routes and provider webhook routes are exceptions to Cognito JWT authorization; webhooks verify provider signatures. Every admin handler calls `require_admin`, which checks the `Admins` claim and then does a live Cognito lookup ([Backend authorization](cognito-authentication.md#backend-authorization)).
- **Application data:** one DynamoDB table and shared access helpers in `backend/shared`. DynamoDB stores catalog/customer/order state and the versioned sellable-stock projection plus active reservations. It is not the authority for physical inventory.
- **Identity:** two Cognito user pools, specified in [Cognito authentication](cognito-authentication.md):
  - a customer pool (self sign-up, optional TOTP) with the storefront client;
  - an admin pool (admin-create-only, required TOTP, `Admins` group) with the admin client.

  Both apps use embedded SRP login and account UI and send access tokens to the API. Do not introduce a Hosted UI redirect assumption.
- **Payments:** Stripe and PayPal secrets in environment-scoped Secrets Manager entries. The backend calculates prices and starts provider sessions; only verified provider events can establish payment success. Payment state and inventory-posting state remain distinct.
- **Inventory:** InvenTree is the authority for physical stock, stock locations, adjustments, and kit/component BOMs. The backend synchronizes eligible stock into DynamoDB, checks freshness, reserves atomically, and posts physical movements through durable, idempotent work. Browsers never call InvenTree or receive its credentials.
- **InvenTree hosting:** InvenTree 1.5.6 on one private EC2 host per environment, in an Auto Scaling group of one: t4g.small in dev, t4g.medium in prod covered by a Savings Plan.
  - Caddy terminates TLS with a Let's Encrypt certificate. There is no load balancer.
  - RDS for PostgreSQL 17 is single-AZ in isolated subnets.
  - The django-q2 worker uses PostgreSQL as its broker. Media is in S3.
  - Email goes through the SES API.
  - A NAT instance provides TCP 443 egress.
  - Each environment has its own VPC, which holds only these resources and the VPC-attached inventory Lambdas.
  - The InvenTree HTTPS endpoint is reachable only from those Lambdas and from a Windows jumpbox that staff start manually and reach through an SSM port-forward.
  - Prod hosting targets under $50/month.
  - See [InvenTree integration](inventree-integration.md) for the full design.
- **Infrastructure:** Terraform roots under `infra/dev` and `infra/prod`, reusable modules in `infra/modules`, and deployment automation under `scripts/`. Start in dev and promote reviewed configuration to prod. Use `us-west-2`, except CloudFront ACM certificates in `us-east-1` through the established provider alias.

## Phase 0: Resolve Contracts and Architecture Gates

Each gate's status is recorded once, in the [Architecture decision register](architecture-decisions.md). The linked contract holds the design.

| # | Gate | Status | Register | Contract |
|---|---|---|---|---|
| 1 | InvenTree 1.5.6 hosting: process topology, PostgreSQL-backed django-q2, S3 media, upgrade procedure, health, secret delivery, RDS PostgreSQL 17 with `verify-full` | Accepted | ADR-002, ADR-006 | [InvenTree integration](inventree-integration.md#inventree-host) |
| 2 | Per-environment VPC, CIDRs, NAT instance, subnets and routes, jumpbox staff access, private DNS and TLS | Accepted | ADR-003, ADR-004, ADR-005 | [InvenTree integration](inventree-integration.md#vpc) |
| 3 | Connectivity proofs: private DNS, security-group-restricted Lambda-to-host and host-to-RDS paths, InvenTree UI reachable only from the jumpbox, no public InvenTree endpoint | Pending the dev acceptance tests | – | [InvenTree acceptance tests](inventree-integration.md#acceptance-tests) |
| 4 | Stock model: kit modes, eligibility, units, mappings, BOM rules, no double counting | Proposed; owner decisions open | ADR-011, OPEN-01 | [Inventory data contract](inventree-integration.md#inventory-data-contract) |
| 5 | Order, payment, and inventory lifecycle; provider libraries; the event ledger | Proposed; cancel and refund routes open | ADR-012, OPEN-03, OPEN-04 | [Payment processing](payment-processing.md#order-payment-and-inventory-states) |
| 6 | DynamoDB keys, indexes, cart, reservations, jobs, ledger, timestamps | Proposed | ADR-011, ADR-018, ADR-019 | [DynamoDB data model](dynamodb-data-model.md) |
| 7 | Release workflow and approval gates | Accepted | ADR-013 | [Infrastructure development workflow](infrastructure-development.md#release-workflow) |

Rules:
- Do not implement code that depends on an open question until the owner answers it, or until the register records the default that applies in dev.
- Verify every access pattern against the DynamoDB indexes before coding.
- Complete the register's [owner actions](architecture-decisions.md#owner-actions) before prod go-live.
- Do not create production resources while any security or data-ownership gate remains unresolved.

## Phase 1: Repository and Delivery Foundations

1. Establish the intended layout:

   ```text
   infra/
     bootstrap/
     dev/
     prod/
     modules/
   backend/
     catalog/ cart/ checkout/ orders/ admin/
     webhooks-stripe/ webhooks-paypal/
     sweeper/ inventory-sync/ inventory-jobs/
     shared/
   frontend/
   admin/
   scripts/
   docs/
   ```

   Each `backend/` folder except `shared/` is exactly one Lambda function, with the trigger, VPC placement and role listed in [Backend API](backend-api.md#functions-and-triggers). Change function boundaries only through that document. Keep the two frontends independently buildable and deployable. Keep shared Python code in `backend/shared`; it is bundled into each function's zip, with no Lambda layer ([Packaging](backend-api.md#packaging)).

2. Establish the foundations:
   - remote Terraform state through `infra/bootstrap` (versioned S3 bucket, `use_lockfile`);
   - provider locks and the Terraform version pin;
   - naming and tags;
   - the operator permission sets in [Credentials and permissions](infrastructure-development.md#credentials-and-permissions).

   Treat state and saved plans as secrets. Never commit state, `.terraform/`, plan files, credentials, secrets, or local `*.tfvars`.
3. Add CI checks that need no AWS credentials:
   - Terraform `fmt -check` and `validate` with `-backend=false` for bootstrap, dev, and prod;
   - Python tests and lint, and the zip determinism check with its hash manifest;
   - frontend lint, tests, and build;
   - secret and dependency scanning, and documentation checks.

   CI never plans, publishes, or applies ([Approval gates](infrastructure-development.md#approval-gates)).
4. Document prerequisites, local setup, environment configuration, and the non-production testing process in the README after a runnable vertical slice exists.

## Phase 2: Dev Infrastructure

Implement reusable modules in `infra/modules` and compose them first in `infra/dev`. Follow [Terraform conventions](terraform-conventions.md) and [Infrastructure development workflow](infrastructure-development.md).

Provision in dependency order:

1. State/bootstrap and environment foundations; establish resource tags and outputs.
2. DNS and certificates, including the CloudFront certificate in `us-east-1` where required.
3. Cognito customer and admin user pools, storefront/admin app clients, the admin pool's Admins group, and outputs consumed by API/frontend configuration. Admin users are created by the AWS account owner via CLI, never by Terraform.
4. DynamoDB table and required indexes, with point-in-time recovery/backups and narrowly scoped Lambda IAM policies.
5. Private S3 buckets, CloudFront distributions/OAC, SPA fallback, TLS, logging, and cache invalidation strategy for both apps.
6. API Gateway HTTP API with explicit routes (no `ANY` or `{proxy+}` route), JWT authorizers, and CORS restricted to the environment's CloudFront origins. The ten Lambda functions each get their own role from the [IAM matrix](backend-api.md#iam), with zips from the artifact bucket (no layer) and environment-scoped configuration. Attach only `inventory-sync` and `inventory-jobs` to the VPC.
7. Secrets Manager secret containers and scoped access policies. Populate secret values with the out-of-band runbook in [Secrets](infrastructure-development.md#secrets), never through Terraform. Use sandbox credentials in dev.
8. InvenTree networking, NAT instance, private EC2 host, jumpbox, isolated RDS, S3 media and artifacts, private DNS and Let's Encrypt TLS, SES identity, monitoring, backups, restore capability, and the dev scheduler. Use the modules listed in [InvenTree integration](inventree-integration.md#terraform-modules-and-prerequisites).
   - Both environments run a single node with single-AZ RDS. This is an accepted tradeoff: prod hosting stays under $50/month with a recovery objective measured in hours.
   - Dev runs on demand and is stopped nightly.
9. Inventory and maintenance triggers, per [Functions and triggers](backend-api.md#functions-and-triggers):
   - the `inventory-jobs` SQS queue and DLQ (`maxReceiveCount` 5, visibility timeout 360 s) and its event source mapping (batch size 1, partial batch responses, maximum concurrency 2);
   - EventBridge Scheduler schedules for `sweeper` (every 5 minutes) and `inventory-sync` (a 5-minute full sync in prod only, and daily reconciliation);
   - a Scheduler role limited to invoking those two functions;
   - alarms and operational dashboards.

Use outputs to connect modules rather than duplicating identifiers. Review every dev plan for unexpected replacements, public exposure, IAM overreach, secret values, and state changes. Run formatting/validation and plan review; only apply when an operator explicitly authorizes it.

## Phase 3: InvenTree Dev Service

1. Pin InvenTree 1.5.6 by immutable image digest. The operator's `deploy-dev.sh publish` stage, run outside the VPC, mirrors it into tag-immutable ECR together with the custom Caddy build that includes the `caddy-dns/route53` module. CI has no AWS credentials. Do not use mutable `latest`/`stable` or an unreviewed floating tag.
2. Deploy the gunicorn server, django-q2 worker, and Caddy containers on the private EC2 host.
   - Store PostgreSQL credentials, the InvenTree secret and OIDC keys, and the integration token in environment Secrets Manager secrets. Deliver them through the least-privilege instance role.
   - Never put plaintext values in Terraform configuration/state, user data, AMIs, container definitions, scripts, plans, or logs.
   - Run migrations only through the single one-off migrate step, never implicitly (`INVENTREE_AUTO_UPDATE=false`).
3. Place RDS PostgreSQL 17 in isolated subnets with public access disabled and ingress limited to the InvenTree host security group on PostgreSQL's port. Enforce `sslmode=verify-full`, configure S3 media through the instance role, and test restore into an isolated dev target.
4. Give the host and jumpbox no public IP, no inbound SSH or RDP, and SSM-only management.
   - Limit the host's HTTPS ingress to the inventory Lambda and jumpbox security groups.
   - Keep InvenTree absent from public frontend configuration and public DNS. Only the ACME challenge TXT and SES DKIM records go in the public zone.
5. Initialize users and roles through a controlled setup procedure:
   - Enforce MFA (`LOGIN_ENFORCE_MFA`).
   - Disable exchange-rate updates and update checks: `CURRENCY_UPDATE_INTERVAL=0`, `INVENTREE_UPDATE_CHECK_INTERVAL=0`.
   - Configure SES email through Anymail with the instance role.
   - Create a least-privilege integration identity and rotate its token by the overlap procedure in [Secret rotation](inventree-integration.md#secret-rotation).
6. Validate version-specific InvenTree APIs/schema against pinned documentation. Build explicit SKU-to-part/BOM mappings with unit tests and fail closed on missing or invalid mappings.
7. Pass the [InvenTree acceptance tests](inventree-integration.md#acceptance-tests) before connecting checkout, following the README steps for staff access. They cover private DNS/TLS, Lambda-to-host connectivity, jumpbox access and file transfer, worker processing, S3 persistence, email, RDS backup/restore, health checks, and restricted staff/API access.

## Phase 4: Backend and Inventory Vertical Slice

Build API and data functionality in small, deployable increments:

1. Implement shared response, validation, DynamoDB, Cognito-claim, Secrets Manager, and InvenTree-client utilities in `backend/shared`, bundled into each zip by `scripts/build-lambdas.sh`. The InvenTree client follows [InvenTree client](backend-api.md#inventree-client): named operations only, bounded timeouts, default TLS verification, POSTs never retried after an unknown outcome, sanitized errors, and server-side credentials. Add the import-boundary test with the first shared module.
2. Implement public catalog reads from DynamoDB. Only individually sellable products receive the catalog index keys; kit-only components remain absent from standalone catalog results.
3. Implement Cognito-protected cart and order reads with customer ownership checks. Validate all API inputs before database/provider calls.
4. Implement admin catalog and inventory operations. Require `require_admin` in each handler before any mutation. `admin` never calls InvenTree. Stock adjustments, shipping, and sync requests become audited ADJUST and SHIP jobs or `inventory-sync` invocations, and return 202 ([Async job contracts](backend-api.md#async-job-contracts)). `inventory-jobs` performs the movement and then requests a targeted sync. A decrease larger than `available_qty` is rejected with 409, with no admin override. Never directly edit the projection as if it were physical stock.
5. Implement inventory sync to read eligible physical stock and BOMs, validate mappings, and write a versioned projection without overwriting active checkout reservations. Store source revision/time and last-success time. Make staleness thresholds explicit and observable.
6. Implement checkout with server-calculated prices and an atomic DynamoDB transaction that validates current availability, reserves all required units/components, and creates a pending order. Reject stale or missing projections. Do not trust submitted price or inventory values.
7. Implement payment-provider session/order creation and verified webhook handlers. Add conditional idempotency markers and conditional order-state transitions. Verify Stripe/PayPal dev sandbox configuration before integration testing.
8. Implement durable, idempotent InvenTree stock-posting jobs keyed by order/line item. Keep inventory state separate from payment state. Retire each reservation exactly once as physical stock movement is reflected in the projection. Gate fulfillment on successful stock posting or explicit operator resolution.
9. Implement reservation expiry, payment failure/cancellation release, refund/return policy, bounded retries, dead-letter/operator alerts, and scheduled reconciliation. Never reverse physical stock for a refund unless the business policy and actual movement justify a distinct idempotent stock operation.

Treat any uncertainty about external API behavior as a verification task against the pinned InvenTree/provider docs, not an assumed request/response contract.

## Phase 5: Storefront and Admin Applications

1. Build independent React + Vite applications with isolated package/build/test configuration. Do not import application source between them.
2. Inject environment-specific public configuration at build time: API URL, Cognito User Pool ID and the respective app client ID. These identifiers are public; credentials and provider secrets are not.
3. Implement embedded Cognito SRP signup/login/logout, password recovery and supported MFA flows. Refresh sessions safely and use the current JWT for protected API calls. Admin UI checks the Admins claim for navigation but relies on server-side authorization.
4. Storefront: public catalog/product pages, kit BOM presentation, cart, checkout initiation, payment return states, customer order history, loading/empty/error states, and responsive accessible forms. Keep kit-only components non-purchasable individually.
5. Admin: protected catalog/order/inventory workflows, clear validation and authorization errors, audit-relevant adjustment reasons, and confirmation for destructive operations. Never expose raw InvenTree credentials or a generic InvenTree proxy.
6. Use the API Gateway only for browser-to-backend calls. Keep API/network concerns in a small client layer; validate response shapes and render untrusted text safely.
7. Build static assets only. Verify SPA routing, content security/cache behavior as configured, keyboard and screen-reader states, mobile/desktop layouts, reduced motion, and absence of secrets in generated bundles.

## Phase 6: Integrated Dev Verification

Run the following checks before production promotion:

- **Static and unit checks:** Terraform fmt/validate, Python lint/type checks and unit tests, both frontend lint/test/build/HTML checks, dependency/security scans, and secret scanning.
- **Backend packaging and boundaries:**
  - Two builds from one commit produce identical zips, and each zip imports its handler in a clean `python3.13` arm64 environment.
  - The import-boundary test passes.
  - The route table has no proxy route.
  - IAM Access Analyzer validation passes. `catalog` is denied `GetSecretValue`, and neither inventory function can read the `inventree_app` or RDS master secret.
  - Only `inventory-sync` and `inventory-jobs` have a VPC configuration, and neither can reach port 5432.
- **Infrastructure checks:** review dev plans, IAM permissions, CORS origins, bucket privacy/OAC, TLS, DNS, alarms, backup configuration, and log redaction.
- **Identity/API checks:** the [Cognito acceptance tests](cognito-authentication.md#acceptance-tests):
  - public catalog without a token;
  - protected routes return 401 for no token, an expired token, and another pool's token, and 403 for an ID token;
  - customer isolation (404 on others' orders);
  - non-admin and customer-token rejection from every admin route;
  - admin success with a valid Admins claim, and immediate 403 after group removal;
  - webhook routes reject invalid provider signatures.
- **Catalog/cart checks:** sellable SKU visibility, kit-only exclusion, missing mapping errors, cart persistence and input validation.
- **Concurrency/payment checks:** two simultaneous attempts for the last unit permit at most one reservation; client-tampered prices are ignored; checkout failures release reservations; duplicate/out-of-order webhooks do not duplicate payment transitions.
- **Inventory checks:** freshness rejection, excluded stock locations/states, correct kit/component math without double counting, unavailable/missing parts, InvenTree downtime, retry after partial failure, duplicate job delivery, admin adjustment reconciliation, and alerting on stale projection.
- **Lifecycle checks:** payment succeeds while inventory posting fails (order remains paid but fulfillment blocked); retry posts once; cancellation/expiry releases once; refund does not silently restock; scheduled reconciliation identifies and reports drift.
- **Operational checks:**
  - InvenTree upgrade in dev, in the [InvenTree rollout](infrastructure-development.md#inventree-rollout) order: plan, snapshot, a single migrate step, apply, then an instance refresh. Confirm that the apply alone replaces no host.
  - The [release-workflow acceptance tests](infrastructure-development.md#acceptance-tests).
  - Point-in-time database and versioned media restore into an isolated instance.
  - The database-password and integration-token rotation procedures.
  - The dev nightly stop and ordered start.
  - Log and metric review, and documented incident recovery.

Record test evidence and unresolved limitations. Do not use production customer, payment, inventory, or secret data in dev tests.

## Phase 7: Production Promotion and Operations

1. Freeze and review the tested dev change set. Promote the same intended Terraform/module/application configuration to `infra/prod`, changing only reviewed environment-specific values and secrets.
2. Use separate production credentials and payment-provider live secrets. Verify DNS, certificates, CloudFront origins, Cognito clients, API authorization, database/network restrictions, monitoring, backup retention, and restore readiness before release. InvenTree go-live gates:
   - The t4g EC2 Instance Savings Plan is purchased.
   - The SNS alert subscription is confirmed.
   - The prod InvenTree run rate is under $50/month after one full week.
3. Follow the [release workflow](infrastructure-development.md#release-workflow):
   1. `deploy-prod.sh promote` copies the dev-tested artifacts.
   2. `plan` produces a saved plan.
   3. The operator reviews it, and `approve` pushes the release tag carrying the plan hash.
   4. `apply` runs that exact plan.
4. Follow [Sequencing](infrastructure-development.md#sequencing):
   - artifacts first, then infrastructure and Lambdas, backend smoke tests, then frontends with index-only invalidation;
   - readers before writers, and DynamoDB backfills as separate steps.

   Upgrade InvenTree as its own release, following [InvenTree rollout](infrastructure-development.md#inventree-rollout):
   1. Plan the launch-template change before the outage.
   2. Take an RDS snapshot, stop the worker, and run the single migrate step.
   3. Apply the plan, then start the instance refresh.

   Do not roll back an application image against an incompatible migrated schema. Use the documented restore procedure, then reconcile Terraform with an `import` block.
5. Smoke-test public catalog, Cognito sessions, a controlled payment test strategy, webhook verification, inventory sync, and operator alarms. Monitor errors, stale projections, failed jobs, reservation age, webhook retries, API latency, and stock discrepancies.
6. Define rollback and incident ownership before go-live: disable checkout if inventory/payment consistency is uncertain; retain order/payment records; reconcile before resuming sales; never manually edit physical/projection quantities without an audited procedure.

## Deployment Guardrails

- Start all infrastructure development in `infra/dev`; promote only after validation and review. Do not create infrastructure directly in prod except through a separately approved emergency process.
- Require explicit target selection. Use separate `deploy-dev.sh` and `deploy-prod.sh` entry points, never a shared script whose omitted argument can target prod. Routine CI never triggers a deployment; it holds no AWS credentials.
- Do not run `terraform apply`, `destroy`, state mutation, or AWS mutation without explicit operator authorization. Plan generation and review are not authorization to apply. The gates are in [Approval gates](infrastructure-development.md#approval-gates). An emergency prod change must be backported to dev within 2 days.
- Never commit secrets, Terraform state, generated private configuration, or local `*.tfvars`. Restrict state and artifact access.
- Keep Lambda IAM roles per function and narrowly scoped. Keep browser CORS limited to the correct CloudFront distribution origins.
- Do not expose InvenTree credentials, admin APIs, or operational endpoints in frontend configuration. Avoid a generic InvenTree proxy.
- Keep physical inventory ownership in InvenTree and reservations/order/payment ownership in the defined application data model. Do not claim cross-service atomicity.

## Definition of Done

The website and integration are ready for production only when both applications build and deploy independently; authentication and backend authorization are verified; catalog/cart/checkout/order flows work; provider payment is confirmed only by verified webhooks; InvenTree physical stock and BOMs drive a fresh, reservation-aware sellable projection; inventory movements and retries are idempotent and auditable; operational failures block fulfillment safely and alert operators; production infrastructure has a reviewed plan and approved deployment; and backups, restore, rollback, credential rotation, monitoring, and incident procedures have been exercised or explicitly accepted as residual risks.
