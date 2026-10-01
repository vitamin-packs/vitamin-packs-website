# Architecture Decision Register

This is the single record of architecture decisions and their status. Each decision links to the one document section that holds its contract. Implementation guides link here for status and to that section for detail. Nothing is restated here in enough detail to conflict with it.

Everything below is **design**. As of 2026-09-28 the repository holds only documentation (see [ADR-001](#adr-001-repository-state)). No application, Terraform, or AWS resource described here has been verified as existing.

**Status values:**
- **Accepted:** the owner approved it, or it records a verified fact.
- **Proposed:** architect-resolved design waiting for owner confirmation or dev verification. Implementation may proceed in dev.
- **Open:** needs an owner answer. Do not implement a policy for it beyond the default named here.
- **Superseded:** replaced by the decision named in its status. Kept as history; do not implement it.

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
| Admin order queues, product listing, reporting, table cost drivers | [DynamoDB data model: Admin listing and reporting](dynamodb-data-model.md#admin-listing-and-reporting), [ADR-025](#adr-025-dynamodb-remains-the-application-database) |
| Stock authority, eligibility, kits, sync, movements, reconciliation | [InvenTree integration: Inventory data contract](inventree-integration.md#inventory-data-contract) |
| Order, payment, and inventory state table | [Payment processing](payment-processing.md#order-payment-and-inventory-states) |
| Customer checkout cancel | [Payment processing: Customer Cancel](payment-processing.md#customer-cancel) |
| Customer profile, address book, email mirror, account deletion | [DynamoDB data model: Profile attributes](dynamodb-data-model.md#profile-attributes), [Backend API: Account routes](backend-api.md#account-routes), [ADR-024](#adr-024-customer-profile-and-account-self-service) |
| Refunds and cancelling paid orders | [Payment processing: state table](payment-processing.md#order-payment-and-inventory-states), [ADR-023](#adr-023-refunds-through-the-provider-dashboard) |
| Provider libraries, ledger, idempotency, webhooks | [Payment processing](payment-processing.md) |
| InvenTree hosting, VPC, staff access, DNS/TLS, RDS, cost | [InvenTree integration](inventree-integration.md) |
| Staff access procedure | [README](../README.md#staff-access-to-inventree-windows-jumpbox) |
| Release workflow, approval gates, credentials, secrets, InvenTree rollout | [Infrastructure development workflow](infrastructure-development.md) |
| Terraform structure, naming, safety | [Terraform conventions](terraform-conventions.md) |
| Implementation order and release checklist | [Delivery plan](development-and-deployment-plan.md) |
| First-release order per environment, InvenTree location configuration | [ADR-026](#adr-026-inventree-first-location-ids-by-second-apply), [Eligible stock](inventree-integration.md#eligible-stock) |

## Decisions

### ADR-001: Repository state
- **Status:** Accepted (verified fact), 2026-09-28. Owner: project owner.
- **Context:** Earlier docs claimed that modules, a SPA fallback, and wiring already existed, and said the data-model doc was missing.
- **Decision:** The repository contains `AGENTS.md`, `README.md`, `LICENSE`, `.gitignore`, and `docs/` only. Every module, path, route, and resource in the docs is proposed until it is implemented and verified.
- **Rejected:** Describing planned modules as existing.
- **Consequences:** Docs say "planned" for modules. Implementers confirm repository and AWS state before relying on anything.

### ADR-002: InvenTree hosting
- **Status:** Accepted, 2026-09-28. The InvenTree sender address `contact@vitamin-packs.com` for both environments is accepted, 2026-09-30 (resolves the former OPEN-08). Owner: project owner.
- **Context:** One staff user, a prod budget under $50/month, and RTO/RPO measured in hours.
- **Decision:** InvenTree 1.5.6 pinned by digest, on one EC2 host per environment (an Auto Scaling group of one). It runs gunicorn, a django-q2 worker with a PostgreSQL broker, and Caddy. There is no Redis, media is in S3, and email goes through the SES API from `contact@vitamin-packs.com` in both dev and prod. → [InvenTree Host](inventree-integration.md#inventree-host)
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
- **Decision:** Eleven flat Python functions: eight HTTP functions, `sweeper`, `inventory-sync`, and `inventory-jobs`. The eighth HTTP function, `account`, was added by [ADR-024](#adr-024-customer-profile-and-account-self-service) on 2026-09-29. Only the two inventory functions attach to the VPC. Routes are explicit, with no proxy route. → [Functions and triggers](backend-api.md#functions-and-triggers)
- **Rejected:** Seven "domains" with inventory nested under webhooks, VPC-attached payment functions, and a generic InvenTree proxy.
- **Consequences:** Payment and Cognito calls never depend on the NAT instance. `admin` reaches InvenTree only through jobs.

### ADR-008: Lambda packaging
- **Status:** Proposed, 2026-09-28. Owner: project owner.
- **Decision:** `backend/shared` is bundled into each deterministic zip, with no Lambda layer. Each function has its own hash-locked dependencies. → [Packaging](backend-api.md#packaging)
- **Rejected:** A shared Lambda layer, because of version skew, a second artifact per change, and mixed dependency sets.
- **Consequences:** A `shared/` change redeploys every function, which is intended.

### ADR-009: Cognito pools and tokens
- **Status:** Proposed, 2026-09-28. The owner accepted two parts: HTTP APIs answering an ID token with 403, and 90-day CloudTrail Event history instead of a dedicated trail. Managing Cognito admin users with the account owner's own administrator access is accepted, 2026-09-30 (resolves the former OPEN-06). Owner: project owner.
- **Decision:** Separate customer and admin pools on the Lite tier, set explicitly because the default tier is Essentials. SRP only; admin pool admin-create-only with TOTP required. Browsers send access tokens, and the authorizers require the `aws.cognito.signin.user.admin` scope. The account owner creates, disables, and re-groups admin users with their own administrator access. No Identity Center permission set carries the `cognito-idp:Admin*` user-management actions. → [Cognito authentication](cognito-authentication.md), [Admin onboarding](cognito-authentication.md#admin-onboarding-audit-revocation-and-recovery)
- **Rejected:** One shared pool, the Hosted UI, and sending ID tokens.
- **Consequences:** Customer tokens can stay valid for up to 30 minutes after revocation. Admin-user management is not least-privilege: it rides on full administrator access. A dedicated permission set, or a second person managing admin users, needs a new decision.

### ADR-010: Admin authorization
- **Status:** Proposed, 2026-09-28. Owner: project owner.
- **Decision:** `require_admin` parses `cognito:groups` tolerantly and then checks live admin-pool membership on every request. It fails closed: 403, or 503 when Cognito is unreachable. → [Backend authorization](cognito-authentication.md#backend-authorization)
- **Rejected:** Trusting the claim alone, and caching the live check.
- **Consequences:** Two Cognito calls per admin request, which is acceptable at single-user volume.

### ADR-011: Inventory data contract
- **Status:** Proposed, 2026-09-28. The owner accepted the hold durations. Treating SHIP stock as fungible within the committed location is accepted, 2026-09-30 (resolves the former OPEN-07). Selling no trackable, serialized, batch-traced, or expiring parts is accepted, 2026-09-30 (resolves OPEN-01 item 8). Kits being `COMPONENTS` by default, with `STOCKED_PART` as a deliberate per-kit exception, is accepted, 2026-09-30 (resolves OPEN-01 item 1). Selling only `OK`-status stock from individually allowlisted locations is accepted, 2026-09-30 (resolves OPEN-01 item 2). The two-step movement (COMMIT at payment, SHIP at shipping) and the location names `Web orders – committed` and `Returns – inspection` are accepted, 2026-09-30 (resolves OPEN-01 item 3). Leaving a late payment that cannot be re-reserved to the operator is accepted, 2026-09-30 (resolves OPEN-01 item 5). Owner decisions remain open: see [OPEN-01](#open-questions). Owner: project owner.
- **Decision:**
  - InvenTree is the sole physical-stock authority.
  - DynamoDB holds a per-part derived projection (`observed_qty`, `reserved_qty`, `available_qty`) and a reservation ledger. Products carry no quantity.
  - Movements run as idempotent COMMIT, UNCOMMIT, and SHIP jobs. The movement is two-step: COMMIT transfers stock to `Web orders – committed` at verified payment, and SHIP removes it from there at shipping. Returns go to `Returns – inspection`.
  - SHIP stock is fungible: SHIP removes any stock of the part in the committed location. It does not target the stock items that the order's COMMIT moved there.
  - No sold part is trackable, serialized, batch-traced, or expiring. A trackable part is a mapping error.
  - Kits are fulfilled from component stock (`COMPONENTS`) by default. A kit is `STOCKED_PART` only by a deliberate per-kit mapping.
  - Only `OK`-status stock in individually allowlisted locations is sellable. Structural, external, committed, and returns locations are never sellable.
  - A late payment after an expired hold re-reserves. If that fails, the order is `paid` / `needs_attention` with `payment_exception = late_unreserved`, and the operator refunds it or holds it until stock arrives.
  
  → [Inventory data contract](inventree-integration.md#inventory-data-contract), [Physical movements](inventree-integration.md#physical-movements), [Inventory projection and reservations](dynamodb-data-model.md#inventory-projection-and-reservations)
- **Rejected:** A product `inventory_count` with a decrement, synchronous InvenTree calls at checkout, TTL-based hold expiry, and removing stock at payment.
- **Consequences:** Checkout fails closed when a projection is stale (20 minutes). Fulfillment is blocked until COMMIT completes. InvenTree records how many units shipped for an order, not which batch or serial went to which order. Per-order batch or serial traceability needs a new decision. So does selling a trackable, serialized, batch-traced, or expiring part: it would need serial selection in COMMIT and SHIP, and it conflicts with fungible SHIP stock. A `late_unreserved` order waits on the operator; refunding it automatically or adding a backorder state needs a new decision.

### ADR-012: Payment lifecycle
- **Status:** Proposed, 2026-09-28. Owner: project owner.
- **Decision:**
  - `stripe==15.6.1` plus a thin `requests` PayPal client.
  - Fetch-then-act, with a payment-event ledger whose `SUCCEEDED` state is written in the same transaction as the business effect.
  - The PayPal capture route captures but never marks an order paid.
  
  → [Payment processing](payment-processing.md)
- **Rejected:** Standard-library HTTP, `paypal-server-sdk`, `paypalrestsdk`, and a separate "processed" marker.
- **Consequences:** Only a verified provider object can set `paid`. The customer cancel route is decided in [ADR-022](#adr-022-customer-checkout-cancel). Refunds and cancelling a paid order go through the provider dashboard: see [ADR-023](#adr-023-refunds-through-the-provider-dashboard).

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
- **Status:** Superseded by [ADR-027](#adr-027-stock-adjustments-in-inventree-only), 2026-09-30. Accepted, 2026-09-28. Owner: project owner.
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
- **Status:** Accepted, 2026-09-28. Keeping the `vitamin-packs-<env>-*` bucket names with no fallback chosen in advance is accepted, 2026-09-30 (resolves the former OPEN-09). Owner: project owner.
- **Context:** Examples mixed `<project>`, `vp-`, and `diyhobbies`.
- **Decision:** `project = "vitamin-packs"`, so resources are named `vitamin-packs-<env>-<purpose>` (for example `vitamin-packs-prod-jumpbox`). The short `vp-` prefix is **not** the project value, and it stays where it is used today:
  - identifiers sent to providers and InvenTree, which have length limits: `vp-<env>-<orderId>-…` idempotency keys, PayPal `invoice_id`, and InvenTree `job_key`;
  - Identity Center permission-set and CLI profile names such as `vp-dev-deployer` and `vp-prod-operator`.
  
  → [Terraform conventions](terraform-conventions.md)
- **Consequences:** S3 bucket names are global, so a `vitamin-packs-<env>-*` bucket name may already be taken. No fallback name is chosen in advance. If a deployment fails on a bucket name, the owner makes a new naming decision then.

### ADR-018: Timestamp format
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:**
  - Every stored timestamp is a UTC ISO 8601 string in the fixed format `YYYY-MM-DDTHH:MM:SSZ`. It is compared directly in conditions and embedded directly in GSI sort keys.
  - Exceptions: `ttl` (Number, epoch seconds; DynamoDB TTL requires it), `sync_version` (an epoch-ms version counter), and provider fields that take epoch seconds, converted at the call.
  
  → [DynamoDB data model: Timestamps](dynamodb-data-model.md#timestamps)
- **Rejected:** Epoch numbers everywhere, and the earlier mix of ISO and epoch values.
- **Consequences:** Writers must use the shared `iso()` helper. A second-precision, fixed-width format is mandatory, or sort order breaks.

### ADR-019: Cart schema and lifecycle
- **Status:** Schema accepted. Lifecycle proposed. 2026-09-28. The abandoned-cart TTL of 15 days is accepted, 2026-09-30 (resolves the former OPEN-05). Owner: project owner.
- **Context:** The checkout pseudocode used cart fields that were never defined.
- **Decision:**
  - `lines`, `version`, `checkout_order_id`, `updated_at`, and `ttl`.
  - The cart is locked while a checkout is open.
  - The verified-payment transaction deletes the cart. A release from `HELD` unlocks it.
  - `ttl` is the last write + 15 days. Every write resets it, so an abandoned cart expires 15 days after its last change. DynamoDB deletes it within a few days after that.
  
  → [Cart attributes](dynamodb-data-model.md#cart-attributes)
- **Rejected:** Clearing the cart at checkout time, which loses the lines if payment fails.
- **Consequences:** Row 6 grows to 5 transaction items, and a release to at most 5 + P. The cart stays locked until payment, a customer cancel ([ADR-022](#adr-022-customer-checkout-cancel)), or hold expiry.

### ADR-020: InvenTree DB host parameter
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:** The `rds-postgres` module manages the SSM parameter `/<project>/<env>/inventree/db-host` and outputs `db_host_parameter_name`. → [Terraform modules](inventree-integration.md#terraform-modules-and-prerequisites), [restore procedure](inventree-integration.md#rds-postgresql)
- **Consequences:** After a restore, the reviewed `import` plan brings the parameter back under Terraform.

### ADR-021: InvenTree host S3 egress port
- **Status:** Accepted, 2026-09-28. Owner: project owner.
- **Decision:** The `inventree` security group allows only TCP 443 to the S3 prefix list. Port 80 is removed, and is re-added only on a demonstrated need as a new decision. → [Security Groups](inventree-integration.md#security-groups)
- **Consequences:** If AL2023 package installs or ECR layer pulls fail over the S3 gateway endpoint during dev acceptance, record the evidence and revisit.

### ADR-022: Customer checkout cancel
- **Status:** Accepted, 2026-09-29 (resolves the former OPEN-04). Owner: project owner.
- **Decision:**
  - `POST /checkout/cancel` on the `checkout` function (`customer-jwt` plus the order ownership check) cancels an unpaid checkout and unlocks the cart.
  - Only an order in `pending` with a `HELD` reservation can be cancelled. `payment_pending` and every later state return 409.
  - The route first makes the provider object unpayable, using the same confirmation as the hold-expiry sweeper. Only then does it run the existing release with `release_reason = customer_cancelled`.
  - The storefront calls it on the provider `cancel_url` return and from a "Cancel checkout" action on the locked cart.

  → [Customer Cancel](payment-processing.md#customer-cancel)
- **Rejected:** Cancelling `payment_pending`, because a PayPal pending capture has money in flight. Putting the route on `orders`, which is read-only and holds no provider secrets. Cancelling implicitly on any cart edit.
- **Consequences:** Customer cancel is its own state-table row (4a), separate from row 4's payment failure. Row 7 is unchanged: a payment after a customer cancel is `unexpected_payment`, alerted, and refunded by the operator. Cancelling a paid order is still a provider-dashboard refund ([ADR-023](#adr-023-refunds-through-the-provider-dashboard)).

### ADR-023: Refunds through the provider dashboard
- **Status:** Accepted, 2026-09-29 (resolves the former OPEN-03). Owner: project owner.
- **Decision:**
  - The admin app has no refund route and no route to cancel a paid order.
  - The operator refunds in the Stripe or PayPal dashboard. Cancelling a paid order means a full refund.
  - The provider's refund event drives the order and inventory state (rows 11–13, 15, and 15a).

  → [Payment processing: state table](payment-processing.md#order-payment-and-inventory-states)
- **Rejected:** An admin refund or cancel route. It would need `admin` access to the provider secrets, IAM changes, and a refund idempotency key.
- **Consequences:** No admin code touches the provider secrets. The Stripe restricted key needs only read access to Refunds. Every operator refund, including rows 6d and 7 and `unexpected_payment`, goes through the dashboard. Automatic refunds of late payments would need a new decision ([ADR-011](#adr-011-inventory-data-contract)).

### ADR-024: Customer profile and account self-service
- **Status:** Proposed, 2026-09-29. The owner chose the scope (contact details and an address book), the ship-to snapshot, and self-service deletion. The contract details await confirmation. Shipping to US states only is accepted, 2026-09-30 (resolves the former OPEN-10). Keeping an order's `ship_to` and `contact_email` indefinitely is accepted, 2026-09-30 (resolves the former OPEN-11). Owner: project owner.
- **Context:** `USER#<sub>` / `PROFILE` had no attributes or writer. Access tokens carry no email, and no document said how an order gets a shipping address.
- **Decision:**
  - One profile item holds display name, phone, marketing opt-in, a mirror of the Cognito email, and up to 5 embedded addresses with a default. Every write is version-guarded.
  - Cognito is the email authority. Only the new `account` function writes the mirror, from `AdminGetUser`. The customer pool keeps the old email until a new one is verified.
  - Checkout takes a saved `addressId` and copies the address and email onto the order (`ship_to`, `contact_email`). Stripe and PayPal do not collect shipping. PayPal gets `SET_PROVIDED_ADDRESS`.
  - Orders ship only to the 50 US states and DC: `SHIP_COUNTRIES = ["US"]` and `SHIP_REGIONS` is their 51 two-letter USPS codes, in both dev and prod. Territories (PR, GU, VI, AS, MP) and military addresses (AA, AE, AP) are not served. Address writes and checkout reject anything else with 400.
  - `POST /account/delete` requires a sign-in within 10 minutes and no open checkout. It tombstones the profile, deletes the cart, then deletes the Cognito user. Orders are kept.
  - An order's `ship_to` and `contact_email` are kept with the order indefinitely, including after the customer deletes their account. Nothing scrubs or expires them.

  → [Profile attributes](dynamodb-data-model.md#profile-attributes), [Account routes](backend-api.md#account-routes), [Account deletion](backend-api.md#account-deletion)
- **Rejected:**
  - Separate address items, which need a second read and cannot switch the default atomically.
  - Provider-collected shipping, which leaves the address outside our order record until the webhook.
  - A Cognito post-confirmation trigger to create profiles; the profile is created lazily on the first write.
  - Amplify `deleteUser` from the browser, which could skip the checkout and cleanup checks.
- **Consequences:** ADR-007 grows to eleven functions. The `account` role gets customer-pool `AdminGetUser`, `AdminUserGlobalSignOut`, and `AdminDeleteUser`. The checkout transaction budget is unchanged. Orders keep personal data indefinitely after an account is deleted, so the privacy notice must say so. A scrub job or a retention limit needs a new decision. Widening `SHIP_COUNTRIES` or `SHIP_REGIONS` needs a new decision, because address validation covers only US state formats.

### ADR-025: DynamoDB remains the application database
- **Status:** Proposed, 2026-09-29. Owner: project owner.
- **Context:** A review asked whether SQL, or a mix of SQL and DynamoDB, would perform better or make storefront and admin features easier. The review excluded the InvenTree database. It found that `GET /admin/orders`, `GET /admin/products`, and `GET /products` had no defined access pattern.
- **Decision:**
  - The single DynamoDB table stays the only store for catalog, cart, profile, order, payment, reservation, and job data.
  - The missing access patterns are added on GSI1: `ORDERS#<status>` on order headers and `CATEGORIES` on category items. The admin product list is a filtered Scan. Reports aggregate over the order partitions in Lambda.
  
  → [Admin listing and reporting](dynamodb-data-model.md#admin-listing-and-reporting), [GSI1](dynamodb-data-model.md#gsi1--catalog-browsing-and-admin-order-queues)
- **Rejected:**
  - RDS PostgreSQL for the application: about $14/month (the prod total goes over $50), and every DB-using function would need the VPC, so checkout, webhooks, and `account` would depend on the NAT instance (contradicts ADR-003 and ADR-007).
  - Aurora Serverless v2 with the Data API: about $44/month at the 0.5 ACU minimum. The 5-minute sync keeps it from pausing.
  - Splitting the data across SQL and DynamoDB: checkout, payment, release, and commit completion each rely on one atomic transaction across cart, order, reservation, projection, and ledger.
  - A read-only SQL copy (Streams to SQL) for the admin app: the SQL cost plus a pipeline, for needs that GSI1 and Lambda aggregation meet.
  - A database on the InvenTree RDS instance: it breaks the rule that no Lambda has a network path to PostgreSQL.
- **Consequences:**
  - SQL gave no performance gain at this volume. The table stays at a few dollars a month, and the main cost is the inventory sync ([Cost drivers](dynamodb-data-model.md#cost-drivers)).
  - Every `status` write also sets `GSI1PK`. There is no new transaction action.
  - `admin` gets `Query` on GSI1 and `Scan` on the table.
  - Revisit if ad-hoc admin reporting becomes a core need, or if order volume makes Lambda aggregation slow. Evaluate DynamoDB export to S3 with Athena first, then Aurora DSQL (serverless, no VPC). Measure DSQL's cost and check its limits before choosing it.

### ADR-026: InvenTree first, location IDs by second apply
- **Status:** Accepted, 2026-09-30. Owner: project owner.
- **Context:** The inventory Lambdas need InvenTree location IDs: the sellable locations and the committed and returns locations. Those IDs only exist once InvenTree is installed and staff have created the locations, and they differ between dev and prod.
- **Decision:** Each environment is released in three steps, all in its existing Terraform root:
  1. **InvenTree foundation release.**
     - It contains bootstrap and network, the NAT instance, and all InvenTree security groups. That includes `inv-lambda`, which is created now and used later.
     - It also contains the private zone, ECR, S3 media and artifacts, the InvenTree secret containers, the EC2 host, RDS, the jumpbox, SES, monitoring, and the dev scheduler.
     - There are no application resources.
  2. **InvenTree setup.** Staff work in the InvenTree UI through the jumpbox:
     - users and MFA, and the integration user and its token;
     - the location tree, including the committed and returns locations;
     - parts and BOMs.
     
     The operator records the location IDs and the part map.
  3. **Application release.** It contains Cognito, DynamoDB, the sites, the API and Lambdas, queues and schedules, and the committed locals file `infra/<env>/inventree-locations.tf`, which holds `eligible_ids`, `committed_id`, and `returns_id`.

  Prod follows the same order: prod InvenTree is live and configured before the first prod application release.

  → [Delivery plan](development-and-deployment-plan.md#phase-2-inventree-foundation), [Eligible stock](inventree-integration.md#eligible-stock), [InvenTree client](backend-api.md#inventree-client)
- **Rejected:**
  - An SSM parameter set out of band: location changes would skip git and plan review.
  - Resolving locations by name at sync time: renaming a location in InvenTree would silently change what is sellable.
  - An admin-app setting: it would need a new route and UI.
  - A `*.tfvars` file: those are gitignored and never committed, and the IDs are not secret.
- **Consequences:**
  - An empty list or a null ID disables inventory. Sync writes no projections, records `LOCATIONS_UNCONFIGURED`, and alarms. Checkout returns 503 for every part.
  - Every sync run checks the IDs against InvenTree first. If a check fails, the run writes nothing. Projections then go stale, and checkout fails closed after the 20-minute freshness limit.
  - Changing a location ID changes `eligibility_version` and therefore `mapping_version`. Carts priced against the old mapping are asked to review.
  - The location IDs are configuration, not an owner decision. The location *policy* is accepted in [ADR-011](#adr-011-inventory-data-contract).

### ADR-027: Stock adjustments in InvenTree only
- **Status:** Accepted, 2026-09-30 (resolves the former OPEN-02; supersedes [ADR-014](#adr-014-no-admin-override-for-stock-decreases)). Owner: project owner.
- **Decision:**
  - The admin app has no stock-adjustment route, and there is no ADJUST job.
  - Staff add, remove, count, and transfer stock in the InvenTree UI through the jumpbox. The next sync picks the change up.
  - The admin sync request (`POST /admin/inventory/sync`) refreshes the projection without waiting for the schedule.

  → [InvenTree integration: Admin stock changes](inventree-integration.md#admin-stock-changes)
- **Rejected:** Add, remove, and count from the admin app (the former default), and count only. With one staff user who already works in InvenTree, neither justifies a fourth job kind.
- **Consequences:**
  - InvenTree does not know about checkout reservations, so a removal there can take units that an open checkout holds. Nothing rejects it. Reconciliation alerts when `available_qty` goes negative.
  - `inventory-jobs` no longer invokes `inventory-sync`, so it loses that permission.
  - Adding admin stock adjustments later needs a new decision, and the job kind is deployed readers-first ([Async job contracts](backend-api.md#async-job-contracts)).

## Open questions

Each question has a default that applies in dev. Prod needs an answer.

| ID | Question | Default until decided | Blocks |
|---|---|---|---|
| OPEN-01 | Inventory owner decisions 6–7 and 9–15 ([list](inventree-integration.md#inventory-owner-decisions)): automatic UNCOMMIT and returns, optional and consumable BOM lines, cart limits, the SKU-to-part rule, sync and freshness intervals, allocation subtraction, partial refunds and disputes, legacy `inventory_count`, storefront availability display | As listed there | Prod go-live; the dev mapping data |

## Owner actions

These are not design decisions. They must be done before prod go-live ([Open Owner Actions](inventree-integration.md#open-owner-actions)):
- Buy the one-year t4g EC2 Instance Savings Plan.
- Confirm the SNS alert email subscription.
- Bootstrap remote state (`infra/bootstrap`) and create the Identity Center permission sets ([Credentials and permissions](infrastructure-development.md#credentials-and-permissions)).

## Implementation-blocker checklist

**Before the first dev Terraform apply (the InvenTree foundation release, [ADR-026](#adr-026-inventree-first-location-ids-by-second-apply)):**
- [ ] Remote-state bootstrap exists and the permission sets are created.
- [ ] CI runs the credential-free checks ([Approval gates](infrastructure-development.md#approval-gates)).

**Before backend code that depends on a contract:**
- [ ] `backend/shared` provides `iso()` and `now_iso()` helpers, with tests for the fixed format (ADR-018).
- [x] The customer profile (`USER#<sub>` / `PROFILE`) contract is defined ([ADR-024](#adr-024-customer-profile-and-account-self-service)). Implement the `account` function before checkout, which needs a saved address.
- [ ] Before the application release: InvenTree setup is complete, and the location IDs are committed in `infra/<env>/inventree-locations.tf` along with the part map. The dev defaults for OPEN-01 are applied in that configuration ([ADR-026](#adr-026-inventree-first-location-ids-by-second-apply)).

**To verify in dev (evidence required before prod):**
- [ ] Capture a real admin-route event and commit it as the `cognito:groups` test fixture ([Cognito](cognito-authentication.md#cognitogroups-in-the-lambda-event)).
- [ ] Check InvenTree 1.5.6 `/api-doc/` shapes for transfer and remove, and for tracking search ([InvenTree client](backend-api.md#inventree-client)).
- [ ] Confirm the host health timer works. It calls `https://localhost/api/system/health/`, but Caddy's certificate is issued for the InvenTree FQDN, so the timer must either call the FQDN (resolved to the host) or send the right Host/SNI. Record the working form in the [Health](inventree-integration.md#health-deployment-and-persistence) section.
- [ ] Confirm the GSI2 projection includes the attributes the sweepers read ([GSI2 overloads](dynamodb-data-model.md#gsi2-overloads-for-inventory-operations)).
- [ ] Confirm the Lite-tier customer pool honors `attributes_require_verification_before_update = ["email"]` ([Email change](cognito-authentication.md#email-change)).
- [ ] Confirm the PayPal sandbox accepts `shipping_preference=SET_PROVIDED_ADDRESS` with `purchase_units[0].shipping`, and that the buyer cannot change it ([PayPal](payment-processing.md#paypal)).
- [ ] Confirm package installs and ECR layer pulls succeed with 443-only S3 egress (ADR-021).
- [ ] Confirm the exact SES action set, and that `subst` drives appear in `mstsc`.
- [ ] Run every acceptance-test list: [InvenTree](inventree-integration.md#acceptance-tests), [inventory](payment-processing.md#inventory-acceptance-tests), [payment](payment-processing.md#payment-acceptance-tests), [Cognito](cognito-authentication.md#acceptance-tests), and [release workflow](infrastructure-development.md#acceptance-tests).

**Before prod go-live:**
- [ ] OPEN-01 answered.
- [ ] The privacy notice states that order shipping addresses and contact emails are kept indefinitely, including after account deletion ([ADR-024](#adr-024-customer-profile-and-account-self-service)).
- [ ] Owner actions complete.
- [ ] Prod run rate under $50/month after one week.
