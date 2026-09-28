# Architecture Resolution Prompt Pack

Use these prompts with an AWS architecture/infrastructure specialist and an InvenTree integration specialist to resolve the open design decisions before implementation. Run the prompts in order; later prompts depend on earlier decisions. The repository currently contains design documentation, not the described application or Terraform implementations, so distinguish verified repository facts from proposed design.

## Shared Instructions

Paste this preamble before any prompt below:

```text
Act as a senior AWS solutions architect and InvenTree integration specialist. Review the named repository documents before recommending changes. Verify AWS and InvenTree behavior against current official documentation for the explicitly selected service/release versions; cite the specific documentation page or API/schema evidence for claims that affect architecture. Do not claim resources, modules, routes, functions, or deployments exist unless verified in the repository or AWS account.

Treat the repository documentation as proposed design, not proof of deployment. Preserve the current architectural constraints unless you identify and explain a conflict: separate static storefront/admin apps; API Gateway and Python Lambda backend; Cognito authentication; DynamoDB application data; InvenTree as physical-stock authority; dev-first Terraform; no public InvenTree endpoint; and no infrastructure mutation without explicit authorization.

For each decision, state the recommendation, alternatives and tradeoffs, assumptions, security and operational impact, implementation consequences, and acceptance tests. Separate decisions that can be made now from questions requiring owner input. Do not apply Terraform, change AWS resources, create credentials, or perform deployments. When editing docs, make the smallest consistent updates and list every changed file and unresolved question.
```

## Prompt 1: InvenTree Hosting and VPC Decision

```text
Resolve the deployment design for InvenTree on EC2 and RDS PostgreSQL.

Review:
- docs/inventree-integration.md
- docs/development-and-deployment-plan.md
- docs/application-architecture.md
- docs/backend-api.md
- docs/infrastructure-development.md
- docs/terraform-conventions.md

Decide and document:
1. Whether InvenTree gets a dedicated VPC per environment or shares the wider application VPC. Account for Lambda-to-service reachability, route-table/security-group ownership, future peering, CIDR overlap, and operational complexity.
2. A subnet/route design across at least two AZs: public subnets for NAT only; private application subnets for EC2, internal ALB, and only the required VPC-attached Lambdas; isolated DB subnets for non-public RDS. Specify route tables, NAT/endpoints, and which services must not have internet routes.
3. Internal staff access: choose Client VPN or an SSM port-forward approach, and specify identity/MFA, DNS, authorization, audit, and support for browser access to the InvenTree UI. Do not make the ALB or RDS public as a convenience.
4. EC2 process/deployment topology for the pinned InvenTree release: web, workers, scheduler/beat, reverse proxy, health checks, rolling deployment, and persistence. Resolve whether a single EC2 host is acceptable for dev and how production scales without duplicate schedulers or split-brain state.
5. RDS engine/version, TLS verification, encryption, credentials, backups/PITR, dev versus production Multi-AZ expectations, and restore procedure.
6. Broker/cache and media architecture, including InvenTree-version support, S3 access via instance profile, and backup/restore scope.
7. Internal DNS/TLS design for the ALB and operator clients; verify certificate issuance/trust requirements for private hostnames.
8. Security-group matrix for operator/VPN to ALB, inventory Lambda to ALB, ALB to EC2, and EC2 to RDS/broker/S3/endpoints. Use security-group references where supported and least privilege.

Deliver:
- One selected architecture and a concise text diagram.
- A subnet/CIDR example clearly labeled illustrative, not approved production addressing.
- A port-and-source/destination matrix and route summary.
- Dev/prod differences and cost/availability tradeoffs.
- Required Terraform modules/outputs and deployment prerequisites.
- Verified official references and a list of owner inputs still needed.
- Consistent proposed edits to docs/inventree-integration.md and docs/development-and-deployment-plan.md.

Do not write Terraform or provision resources in this task.
```

## Prompt 2: Inventory Ownership, DynamoDB Projection, and Reservations

```text
Resolve the inventory data contract between InvenTree and DynamoDB. InvenTree is the sole authority for physical stock, locations, stock adjustments, and BOMs. DynamoDB is application storage for catalog/order data plus a derived stock projection and checkout reservations; it must not become a second editable physical-inventory system.

Review:
- docs/dynamodb-data-model.md
- docs/inventree-integration.md
- docs/payment-processing.md
- docs/backend-api.md
- docs/development-and-deployment-plan.md

The current DynamoDB document has an inventory_count product field and an atomic decrement example, while the InvenTree document requires a versioned projection and active reservation ledger. Design a consistent replacement/extension that specifies:
1. Which DynamoDB records/attributes represent InvenTree observed quantity, projected sellable availability, active reservation quantity, source revision/time, freshness, and mapping version.
2. Atomic checkout reservation for individual products and component-based kits, including last-unit concurrency, multi-component DynamoDB transaction limits, insufficient stock, and stale/missing projection behavior.
3. How periodic sync updates physical observations without clobbering reservations or creating transient oversell windows.
4. How payment confirmation, failed payment, cancellation, expiry, refund, return, and fulfillment interact with reservation and InvenTree movement states.
5. How a successful physical movement is made idempotent across retries and then reflected in the projection exactly once; account for manual stock changes in InvenTree and delayed/failed syncs.
6. Kit/BOM policy: finished kits versus component-derived availability; unit conversions; eligible locations and stock states; non-stocked parts; and avoiding component double counting.
7. Required access patterns, table/index changes (if any), conditional expressions, TTL use (if appropriate), and reconciliation queries.

Deliver:
- A state-transition table for order/payment/inventory/reservation states.
- Proposed DynamoDB entity/key/attribute design and transactions, with pseudocode for checkout reservation, sync, movement completion, and release.
- Failure/retry/reconciliation behavior and measurable freshness/reservation-expiry policy recommendations.
- Migration implications for existing catalog seed data and the existing inventory_count field.
- Updated proposed text for docs/dynamodb-data-model.md, docs/inventree-integration.md, and docs/payment-processing.md.
- Explicit business decisions that cannot safely be inferred.

Do not implement application code or change physical inventory.
```

## Prompt 3: Backend Domains, Lambda Packaging, and Network Boundaries

```text
Resolve backend ownership and deployment boundaries for the Python Lambda API and private InvenTree integration.

Review:
- docs/application-architecture.md
- docs/backend-api.md
- docs/inventree-integration.md
- docs/development-and-deployment-plan.md
- docs/terraform-conventions.md

Resolve these documented inconsistencies:
- Application architecture says seven domains, while backend layout includes inventory-sync and inventory-jobs.
- The backend folder tree currently nests inventory-sync and inventory-jobs under webhooks-paypal.
- Shared code is described as a Lambda layer in one document and copied into each deployment package in another.
- Backend packaging describes a function package for every folder but inventory sync/jobs are scheduled or queue-driven rather than HTTP routes.

Choose and document:
1. Correct domain/function list, directory tree, triggers, event sources, and API Gateway route ownership.
2. A single shared-code packaging strategy (Lambda layer or bundled shared source), including versioning, build artifacts, local tests, dependency isolation, and rollout compatibility.
3. Which functions attach to the VPC and why. Keep payment/provider calls out of the VPC unless a specific need exists; define NAT and VPC endpoint requirements for VPC functions.
4. Least-privilege IAM permissions per function for DynamoDB, SQS, Secrets Manager, CloudWatch, and VPC operation; explicitly exclude direct RDS access from Lambda.
5. InvenTree client placement, configuration, private DNS, connection/timeouts, retries, and error/redaction behavior.
6. How API routes and async job contracts evolve without exposing a generic InvenTree proxy.

Deliver a corrected directory tree, function/trigger/IAM/VPC matrix, selected packaging model with tradeoffs, and concise proposed edits to docs/application-architecture.md, docs/backend-api.md, and docs/development-and-deployment-plan.md. Do not create backend source or Terraform.
```

## Prompt 4: Payments, Webhook Idempotency, and Inventory Handoff

```text
Produce one definitive Stripe and PayPal checkout/payment lifecycle that composes safely with the DynamoDB reservations and asynchronous InvenTree stock movements.

Review:
- docs/payment-processing.md
- docs/backend-api.md
- docs/dynamodb-data-model.md
- docs/inventree-integration.md

Resolve:
1. Exact Stripe and PayPal API/library choices, supported versions, sandbox/live base URLs, timeout behavior, and secret shapes. The current prose says standard-library HTTP clients, but the samples use Stripe SDK symbols and requests.post.
2. PayPal order approval and capture ownership: what the authenticated capture endpoint does, which verified provider event is authoritative for paid status, and how repeated capture calls/webhooks are handled.
3. Provider idempotency keys for checkout creation/capture, webhook signature verification, event ordering, duplicate delivery, unknown events, and replay protection.
4. A webhook processing model that cannot permanently suppress an event if processing fails after writing a receipt marker. Define received/processing/succeeded/failed state, retry behavior, and transaction/outbox approach compatible with Lambda and DynamoDB.
5. Conditions for payment-state transitions and how invalid amount, currency, provider reference, or order status are rejected.
6. Reservation hold duration, cancellation/expiry behavior, late payment after release, refund/chargeback policy, and interaction with pending/failed InvenTree movements.
7. Logging, metrics, alerts, manual recovery, and PII/secret redaction.

Deliver:
- Provider-specific sequence diagrams or numbered flows.
- A combined order/payment/inventory state-transition table.
- An idempotency/event ledger design and pseudocode showing recoverable failure handling.
- Explicit dependency decisions and verified official provider references.
- Proposed edits to docs/payment-processing.md, docs/dynamodb-data-model.md, and docs/inventree-integration.md.

Do not use live credentials or execute provider payments.
```

## Prompt 5: Cognito Sessions, MFA, and Admin Authorization

```text
Resolve Cognito authentication and authorization behavior for the storefront, admin SPA, API Gateway HTTP API, and admin Lambda handlers.

Review:
- docs/cognito-authentication.md
- docs/application-architecture.md
- docs/frontend-applications.md
- docs/backend-api.md

Verify against current AWS Cognito and API Gateway HTTP API documentation, then decide:
1. Whether the browser sends Cognito ID or access tokens to API Gateway and the matching authorizer issuer/audience/scopes configuration. Account for the token claim differences and validate the exact HTTP API behavior.
2. The actual `cognito:groups` representation in the token and a robust Admins membership check in Lambda.
3. Admin account provisioning: whether public signup is allowed for the admin app client, and how initial/admin group membership is granted, audited, revoked, and recovered.
4. SRP login, refresh, logout, password recovery, MFA enrollment, and TOTP challenge handling. The current sample rejects `totpRequired` even though MFA is described as supported.
5. Session storage and XSS/token exposure implications for a static SPA; define practical browser storage/session behavior and expiry handling.
6. Backend authorization as the source of truth, including customer ownership checks and tests proving the admin UI is not the security boundary.

Deliver a concise auth sequence, token/claim contract, admin onboarding/revocation policy, failure behavior, and proposed edits to docs/cognito-authentication.md, docs/backend-api.md, and docs/frontend-applications.md. Include official AWS documentation references. Do not create Cognito resources or users.
```

## Prompt 6: Infrastructure Promotion and Deployment Safety

```text
Reconcile the repository's Terraform and deployment workflow so dev-first delivery is practical without accidental production mutation.

Review:
- docs/infrastructure-development.md
- docs/terraform-conventions.md
- docs/backend-api.md
- docs/application-architecture.md
- docs/development-and-deployment-plan.md

The backend guide's deployment-script example uploads artifacts and runs terraform apply, while other docs say apply/AWS mutation must only occur after explicit authorization. Define a consistent staged workflow for:
1. Formatting, validation, tests, packaging, artifact upload, Terraform plan generation, plan review, approval, apply, application rollout, smoke tests, and rollback.
2. Separate dev/prod entry points and controls. Decide whether deploy scripts may apply at all, or must stop after producing a reviewed plan; make the production approval mechanism explicit and auditable.
3. CI permissions versus operator permissions, protected environments, artifact/state/plan sensitivity, credentials, and secret population outside Terraform state.
4. Lambda and static-site deployment sequencing, InvenTree EC2 image/config rollout, and database migration/restore constraints.
5. What actions require explicit operator approval and which validation actions are safe for routine CI.

Deliver one workflow diagram or ordered procedure, clear script contracts, required approval gates, and consistent proposed edits to docs/backend-api.md, docs/infrastructure-development.md, docs/terraform-conventions.md, and docs/development-and-deployment-plan.md. Do not apply infrastructure or write deployment scripts.
```

## Prompt 7: Documentation Reconciliation and Decision Register

```text
Perform a final documentation-only architecture reconciliation after Prompts 1-6 have been decided.

Review all files in docs/ and the repository root instructions. Verify the repository state instead of assuming the documented applications/resources already exist. Remove stale claims that implementations or Terraform modules are already present unless verified. In particular, check:
- the statement that the DynamoDB data-model document is missing;
- the backend domain count and directory-tree nesting;
- shared Lambda code packaging consistency;
- inventory authority versus DynamoDB inventory_count/decrement behavior;
- payment library/API and webhook/capture lifecycle consistency;
- Cognito MFA, token, and group-claim examples;
- deployment scripts versus explicit apply safety rules;
- EC2/RDS VPC, operator access, private DNS/TLS, and Lambda connectivity statements.

Create/update an architecture decision register with decision ID, status (accepted/proposed/open), context, selected decision, alternatives rejected, consequences, owner, and date. Ensure each implementation guide links to the single authoritative decision/contract rather than duplicating contradictory instructions. Preserve unresolved owner choices as explicit questions; do not silently choose business policies.

Deliver a findings-first list of remaining conflicts, files changed, a link map to authoritative docs, and an implementation-blocker checklist. Do not change code, run deployments, or mutate AWS.
```

## Suggested Run Order

1. Run Prompts 1 and 5 to settle network/hosting and identity boundaries.
2. Run Prompt 2 to settle stock authority, projection, and reservations.
3. Run Prompt 4 using the approved inventory contract.
4. Run Prompt 3 to finalize backend functions, VPC attachment, and packaging.
5. Run Prompt 6 to finalize safe deployment and promotion.
6. Run Prompt 7 to reconcile all documentation and record decisions.
