# Architecture Decision Register

This is the single record of architecture decisions and their status. Each decision links to the one document section that holds its contract. Implementation guides link here for status and to that section for detail. Nothing is restated here in enough detail to conflict with it.

Everything below is **design**. As of 2026-09-28 the repository holds only documentation (see [ADR-001](#adr-001-repository-state)). No application, Terraform, or AWS resource described here has been verified as existing.

**Status values:**
- **Accepted:** the owner approved it, or it records a verified fact.
- **Proposed:** architect-resolved design waiting for owner confirmation or dev verification. Implementation may proceed in dev.
- **Open:** needs an owner answer. Do not implement a policy for it beyond the default named here.

**Owner:** the project owner. They are the sole approver and the only holder of prod deploy rights.

## Contract index

| Topic | Authoritative section |
|---|---|
| Repository layout, frontend/backend split | [Application architecture](application-architecture.md), [Delivery plan: Phase 1](development-and-deployment-plan.md#phase-1-repository-and-delivery-foundations) |
| Lambda functions, triggers, routes, IAM, VPC attachment | [Backend API: Functions and triggers](backend-api.md#functions-and-triggers), [API Gateway](backend-api.md#api-gateway), [IAM](backend-api.md#iam) |
| Lambda packaging | [Backend API: Packaging](backend-api.md#packaging) |
| InvenTree client, async job contracts | [Backend API: InvenTree client](backend-api.md#inventree-client), [Async job contracts](backend-api.md#async-job-contracts) |
| Cognito pools, tokens, claims, `require_admin` | [Cognito authentication](cognito-authentication.md) |
| Browser session storage and CSP | [Cognito: Session storage and XSS](cognito-authentication.md#session-storage-and-xss), [Frontend applications](frontend-applications.md#session-security-and-content-security-policy) |
| DynamoDB keys, indexes, cart, reservations, jobs, timestamps | [DynamoDB data model](dynamodb-data-model.md) |
| Stock authority, eligibility, kits, sync, movements, reconciliation | [InvenTree integration: Inventory data contract](inventree-integration.md#inventory-data-contract) |
| Order, payment, and inventory state table | [Payment processing](payment-processing.md#order-payment-and-inventory-states) |
| Provider libraries, ledger, idempotency, webhooks | [Payment processing](payment-processing.md) |
| InvenTree hosting, VPC, staff access, DNS/TLS, RDS, cost | [InvenTree integration](inventree-integration.md) |
| Staff access procedure | [README](../README.md#staff-access-to-inventree-windows-jumpbox) |
| Release workflow, approval gates, credentials, secrets, InvenTree rollout | [Infrastructure development workflow](infrastructure-development.md) |
| Terraform structure, naming, safety | [Terraform conventions](terraform-conventions.md) |
| Implementation order and release checklist | [Delivery plan](development-and-deployment-plan.md) |

## Decisions

### ADR-001: Repository state
- **Status:** Accepted (verified fact), 2026-09-28. Owner: project owner.
- **Context:** Earlier docs claimed that modules, a SPA fallback, and wiring already existed, and said the data-model doc was missing.
- **Decision:** The repository contains `AGENTS.md`, `README.md`, `LICENSE`, `.gitignore`, and `docs/` only. Every module, path, route, and resource in the docs is proposed until it is implemented and verified.
- **Rejected:** Describing planned modules as existing.
- **Consequences:** Docs say "planned" for modules. Implementers confirm repository and AWS state before relying on anything.

### ADR-002: InvenTree hosting
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Context:** One staff user, a prod budget under $50/month, and RTO/RPO measured in hours.
- **Decision:** InvenTree 1.5.6 pinned by digest, on one EC2 host per environment (an Auto Scaling group of one). It runs gunicorn, a django-q2 worker with a PostgreSQL broker, and Caddy. There is no Redis, media is in S3, and email goes through the SES API. → [InvenTree Host](inventree-integration.md#inventree-host)
- **Rejected:** ECS or multiple nodes, an internal ALB, Redis or ElastiCache, and Celery.
- **Consequences:** A few minutes of downtime during upgrades, inside the 20-minute freshness limit. Scale-out is documented but not built.

### ADR-003: Network and egress
- **Status:** Accepted, 2026-09-28 (the owner approved the CIDRs and rejected interface endpoints for cost). Owner: project owner.
- **Decision:** One VPC per environment (dev `192.168.0.0/19`, prod `192.168.32.0/19`), holding only the InvenTree resources and the two inventory Lambdas. A t4g.nano NAT instance, S3 and DynamoDB gateway endpoints, and no interface endpoints. → [VPC](inventree-integration.md#vpc), [Subnets, Routes and Egress](inventree-integration.md#subnets-routes-and-egress)
- **Rejected:** A shared application VPC, a NAT gateway, interface endpoints, and Transit Gateway or peering.
- **Consequences:** If the NAT fails, sync and jobs stop, and checkout fails closed after 20 minutes. `192.168.x` rules out a future site-to-site VPN without readdressing.

### ADR-004: Staff access
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:** A Windows jumpbox (desired capacity 0 by default), reached through an SSM port-forward and RDP, with Identity Center MFA and InvenTree MFA. Files move through the redirected `T:` drive. → [Staff Access](inventree-integration.md#staff-access)
- **Rejected:** Client VPN, a public ALB, an S3 transfer bucket, and an admin-app upload proxy.
- **Consequences:** Jumpbox egress to SSM goes through the NAT instance. The owner accepted that the host firewall, not the security group, limits browsing.

### ADR-005: Private DNS and TLS
- **Status:** Accepted, 2026-09-28 (the owner accepted Certificate Transparency exposure). Owner: project owner.
- **Decision:** A private hosted zone whose apex is exactly the InvenTree hostname. Caddy obtains a Let's Encrypt certificate by DNS-01 in the public zone. No AWS Private CA. → [TLS and Private DNS](inventree-integration.md#tls-and-private-dns)
- **Rejected:** A private zone for `vitamin-packs.com`, a Private CA, and an internal ALB with ACM.
- **Consequences:** The hostnames appear in CT logs. The certificate is backed up to S3 to stay under rate limits.

### ADR-006: RDS PostgreSQL
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:** PostgreSQL 17, db.t4g.micro, single-AZ, `verify-full` TLS, PITR with 7-day retention, and manual `inventree_app` password rotation. → [RDS PostgreSQL](inventree-integration.md#rds-postgresql)
- **Rejected:** Multi-AZ (cost) and a rotation Lambda (it would need a network path to RDS).
- **Consequences:** RTO in hours, RPO about 5 minutes. The restore procedure is rehearsed quarterly.

### ADR-007: Backend functions and VPC attachment
- **Status:** Proposed, 2026-09-28. Owner: project owner.
- **Decision:** Ten flat Python functions: seven HTTP functions, `sweeper`, `inventory-sync`, and `inventory-jobs`. Only the two inventory functions attach to the VPC. Routes are explicit, with no proxy route. → [Functions and triggers](backend-api.md#functions-and-triggers)
- **Rejected:** Seven "domains" with inventory nested under webhooks, VPC-attached payment functions, and a generic InvenTree proxy.
- **Consequences:** Payment and Cognito calls never depend on the NAT instance. `admin` reaches InvenTree only through jobs.

### ADR-008: Lambda packaging
- **Status:** Proposed, 2026-09-28. Owner: project owner.
- **Decision:** `backend/shared` is bundled into each deterministic zip, with no Lambda layer. Each function has its own hash-locked dependencies. → [Packaging](backend-api.md#packaging)
- **Rejected:** A shared Lambda layer, because of version skew, a second artifact per change, and mixed dependency sets.
- **Consequences:** A `shared/` change redeploys every function, which is intended.

### ADR-009: Cognito pools and tokens
- **Status:** Proposed, 2026-09-28. The owner accepted two parts: HTTP APIs answering an ID token with 403, and 90-day CloudTrail Event history instead of a dedicated trail. Owner: project owner.
- **Decision:** Separate customer and admin pools on the Lite tier, set explicitly because the default tier is Essentials. SRP only; admin pool admin-create-only with TOTP required. Browsers send access tokens, and the authorizers require the `aws.cognito.signin.user.admin` scope. → [Cognito authentication](cognito-authentication.md)
- **Rejected:** One shared pool, the Hosted UI, and sending ID tokens.
- **Consequences:** Customer tokens can stay valid for up to 30 minutes after revocation.

### ADR-010: Admin authorization
- **Status:** Proposed, 2026-09-28. Owner: project owner.
- **Decision:** `require_admin` parses `cognito:groups` tolerantly and then checks live admin-pool membership on every request. It fails closed: 403, or 503 when Cognito is unreachable. → [Backend authorization](cognito-authentication.md#backend-authorization)
- **Rejected:** Trusting the claim alone, and caching the live check.
- **Consequences:** Two Cognito calls per admin request, which is acceptable at single-user volume.

### ADR-011: Inventory data contract
- **Status:** Proposed, 2026-09-28. The owner accepted the hold durations. Owner decisions remain open: see [OPEN-01](#open-questions). Owner: project owner.
- **Decision:**
  - InvenTree is the sole physical-stock authority.
  - DynamoDB holds a per-part derived projection (`observed_qty`, `reserved_qty`, `available_qty`) and a reservation ledger. Products carry no quantity.
  - Movements run as idempotent COMMIT, UNCOMMIT, SHIP, and ADJUST jobs.
  
  → [Inventory data contract](inventree-integration.md#inventory-data-contract), [Inventory projection and reservations](dynamodb-data-model.md#inventory-projection-and-reservations)
- **Rejected:** A product `inventory_count` with a decrement, synchronous InvenTree calls at checkout, and TTL-based hold expiry.
- **Consequences:** Checkout fails closed when a projection is stale (20 minutes). Fulfillment is blocked until COMMIT completes.

### ADR-012: Payment lifecycle
- **Status:** Proposed, 2026-09-28. Owner: project owner.
- **Decision:**
  - `stripe==15.6.1` plus a thin `requests` PayPal client.
  - Fetch-then-act, with a payment-event ledger whose `SUCCEEDED` state is written in the same transaction as the business effect.
  - The PayPal capture route captures but never marks an order paid.
  
  → [Payment processing](payment-processing.md)
- **Rejected:** Standard-library HTTP, `paypal-server-sdk`, `paypalrestsdk`, and a separate "processed" marker.
- **Consequences:** Only a verified provider object can set `paid`. The cancel and refund routes are open: see OPEN-03 and OPEN-04.

### ADR-013: Release workflow and approval gates
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:**
  - CI holds no AWS credentials.
  - The operator runs `deploy-<env>.sh` stages from the workstation and applies only a saved, reviewed plan.
  - Prod apply requires a pushed release tag bound to the plan hash.
  - One AWS account for now. Unsigned annotated tags are allowed. Emergency changes are backported to dev within 2 days.
  
  → [Release workflow](infrastructure-development.md#release-workflow), [Approval gates](infrastructure-development.md#approval-gates)
- **Rejected:** CI-driven apply, GitHub Environment reviewers (not available for this private repository's plan), and a two-person rule.
- **Consequences:** The tag and CloudTrail record are the approval evidence.

### ADR-014: No admin override for stock decreases
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:** An ADJUST decrease larger than `available_qty` is rejected with 409, with no override. → [Async job contracts](backend-api.md#async-job-contracts)
- **Consequences:** Larger corrections are made in the InvenTree UI and picked up by the next sync.

### ADR-015: Payment secret naming
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Context:** `${project}/${environment}/stripe` broke the naming convention and fell outside the permission sets' `${project}-<env>-*` scoping.
- **Decision:** `${project}-${environment}-stripe` and `${project}-${environment}-paypal`. → [Payment processing: Secrets](payment-processing.md#secrets)
- **Rejected:** Slash-path names.
- **Consequences:** Name-scoped IAM covers the payment secrets.

### ADR-016: No Cognito identity pool
- **Status:** Proposed, 2026-09-28. Owner: project owner.
- **Decision:** No identity pool is created. If a need is approved later, federate the admin pool only, with a scoped role. → [What Terraform provides](cognito-authentication.md#what-terraform-provides)
- **Rejected:** An unused identity pool with an empty role "for later".
- **Consequences:** Less IAM surface. Browsers never hold AWS credentials.

### ADR-017: Terraform project value
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Context:** Examples mixed `<project>`, `vp-`, and `diyhobbies`.
- **Decision:** `project = "vitamin-packs"`, so resources are named `vitamin-packs-<env>-<purpose>` (for example `vitamin-packs-prod-jumpbox`). The short `vp-` prefix is **not** the project value, and it stays where it is used today:
  - identifiers sent to providers and InvenTree, which have length limits: `vp-<env>-<orderId>-…` idempotency keys, PayPal `invoice_id`, and InvenTree `job_key`;
  - Identity Center permission-set and CLI profile names such as `vp-dev-deployer` and `vp-prod-operator`.
  
  → [Terraform conventions](terraform-conventions.md)
- **Consequences:** S3 bucket names are global. The first plan review must confirm that `vitamin-packs-<env>-*` bucket names are available ([OPEN-09](#open-questions)).

### ADR-018: Timestamp format
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:**
  - Every stored timestamp is a UTC ISO 8601 string in the fixed format `YYYY-MM-DDTHH:MM:SSZ`. It is compared directly in conditions and embedded directly in GSI sort keys.
  - Exceptions: `ttl` (Number, epoch seconds; DynamoDB TTL requires it), `sync_version` (an epoch-ms version counter), and provider fields that take epoch seconds, converted at the call.
  
  → [DynamoDB data model: Timestamps](dynamodb-data-model.md#timestamps)
- **Rejected:** Epoch numbers everywhere, and the earlier mix of ISO and epoch values.
- **Consequences:** Writers must use the shared `iso()` helper. A second-precision, fixed-width format is mandatory, or sort order breaks.

### ADR-019: Cart schema and lifecycle
- **Status:** Schema accepted. Lifecycle proposed. 2026-09-28. Owner: project owner.
- **Context:** The checkout pseudocode used cart fields that were never defined.
- **Decision:**
  - `lines`, `version`, `checkout_order_id`, `updated_at`, and `ttl`.
  - The cart is locked while a checkout is open.
  - The verified-payment transaction deletes the cart. A release from `HELD` unlocks it.
  
  → [Cart attributes](dynamodb-data-model.md#cart-attributes)
- **Rejected:** Clearing the cart at checkout time, which loses the lines if payment fails.
- **Consequences:** Row 6 grows to 5 transaction items, and a release to at most 5 + P. The cart stays locked until expiry unless [OPEN-04](#open-questions) adds a cancel route.

### ADR-020: InvenTree DB host parameter
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:** The `rds-postgres` module manages the SSM parameter `/<project>/<env>/inventree/db-host` and outputs `db_host_parameter_name`. → [Terraform modules](inventree-integration.md#terraform-modules-and-prerequisites), [restore procedure](inventree-integration.md#rds-postgresql)
- **Consequences:** After a restore, the reviewed `import` plan brings the parameter back under Terraform.

### ADR-021: InvenTree host S3 egress port
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:** The `inventree` security group allows only TCP 443 to the S3 prefix list. Port 80 is removed, and is re-added only on a demonstrated need as a new decision. → [Security Groups](inventree-integration.md#security-groups)
- **Consequences:** If AL2023 package installs or ECR layer pulls fail over the S3 gateway endpoint during dev acceptance, record the evidence and revisit.

## Open questions

Each question has a default that applies in dev. Prod needs an answer.

| ID | Question | Default until decided | Blocks |
|---|---|---|---|
| OPEN-01 | Inventory owner decisions 1–3 and 5–15 ([list](inventree-integration.md#inventory-owner-decisions)): kit modes, eligible locations and statuses, the two-step movement and location IDs, late-payment handling, automatic UNCOMMIT and returns, optional and consumable BOM lines, trackable parts, cart limits, the SKU-to-part rule, sync and freshness intervals, allocation subtraction, partial refunds and disputes, legacy `inventory_count`, storefront availability display | As listed there | Prod go-live; the dev mapping data |
| OPEN-02 | Which ADJUST operations the admin app offers | Add, remove, and count at one eligible location; transfers stay in InvenTree | The admin inventory UI and ADJUST worker |
| OPEN-03 | Should the admin app issue refunds or cancel paid orders? It would need a route, `admin` access to the provider secrets, and IAM changes. | No. Refund in the provider dashboard; the provider event drives state | Admin refund UI; rows 11–13 "cancel" wording |
| OPEN-04 | Should customers be able to cancel an unpaid checkout (`customer_cancelled`, row 4) and unlock their cart? | No route. The hold and cart lock end at expiry (35 minutes) | The storefront return-from-cancel UX |
| OPEN-05 | Abandoned-cart TTL duration | 30 days after the last write | Cart implementation (the value only) |
| OPEN-06 | Which Identity Center permission set may create, disable, and re-group Cognito admin users? | The account owner's own administrator access | Admin onboarding runbook, least privilege |
| OPEN-07 | Is SHIP stock fungible within the committed location, or must it follow batch or serial traceability? | Fungible (see [Physical movements](inventree-integration.md#physical-movements)) | The SHIP job plan |
| OPEN-08 | InvenTree sender addresses (`inventree@`, `inventree-dev@`) | As documented | SES setup |
| OPEN-09 | If a `vitamin-packs-<env>-*` S3 bucket name is taken globally, what naming fallback applies? | None chosen. Confirm availability at the first dev plan | The first dev apply |

## Owner actions

These are not design decisions. They must be done before prod go-live ([Open Owner Actions](inventree-integration.md#open-owner-actions)):
- Buy the one-year t4g EC2 Instance Savings Plan.
- Confirm the SNS alert email subscription.
- Bootstrap remote state (`infra/bootstrap`) and create the Identity Center permission sets ([Credentials and permissions](infrastructure-development.md#credentials-and-permissions)).

## Implementation-blocker checklist

**Before the first dev Terraform apply:**
- [ ] Remote-state bootstrap exists and the permission sets are created.
- [ ] S3 bucket names are confirmed available (OPEN-09).
- [ ] CI runs the credential-free checks ([Approval gates](infrastructure-development.md#approval-gates)).

**Before backend code that depends on a contract:**
- [ ] `backend/shared` provides `iso()` and `now_iso()` helpers, with tests for the fixed format (ADR-018).
- [ ] The customer profile (`USER#<sub>` / `PROFILE`) has no defined attributes or writer. Define them before any handler needs customer email, because access tokens carry none.
- [ ] Record the dev defaults for OPEN-01, OPEN-02, and OPEN-07 in the dev part-map and location configuration.

**To verify in dev (evidence required before prod):**
- [ ] Capture a real admin-route event and commit it as the `cognito:groups` test fixture ([Cognito](cognito-authentication.md#cognitogroups-in-the-lambda-event)).
- [ ] Check InvenTree 1.5.6 `/api-doc/` shapes for the ADJUST endpoint, transfer and remove, and tracking search ([InvenTree client](backend-api.md#inventree-client)).
- [ ] Confirm the host health timer works. It calls `https://localhost/api/system/health/`, but Caddy's certificate is issued for the InvenTree FQDN, so the timer must either call the FQDN (resolved to the host) or send the right Host/SNI. Record the working form in the [Health](inventree-integration.md#health-deployment-and-persistence) section.
- [ ] Confirm the GSI2 projection includes the attributes the sweepers read ([GSI2 overloads](dynamodb-data-model.md#gsi2-overloads-for-inventory-operations)).
- [ ] Confirm package installs and ECR layer pulls succeed with 443-only S3 egress (ADR-021).
- [ ] Confirm the exact SES action set, and that `subst` drives appear in `mstsc`.
- [ ] Run every acceptance-test list: [InvenTree](inventree-integration.md#acceptance-tests), [inventory](payment-processing.md#inventory-acceptance-tests), [payment](payment-processing.md#payment-acceptance-tests), [Cognito](cognito-authentication.md#acceptance-tests), and [release workflow](infrastructure-development.md#acceptance-tests).

**Before prod go-live:**
- [ ] OPEN-01 answered, and OPEN-03, OPEN-04, and OPEN-08 answered or their defaults explicitly accepted.
- [ ] Owner actions complete.
- [ ] Prod run rate under $50/month after one week.
