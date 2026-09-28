# InvenTree Inventory Integration

## Goal and Boundaries

Run InvenTree on Amazon EC2 with Amazon RDS for PostgreSQL, inside the same environment VPC as the backend inventory integration. This is the intended deployment architecture for both dev and prod. The storefront and admin applications continue to use API Gateway and Python Lambda; browsers must not call InvenTree or receive its API credentials.

InvenTree owns physical stock, locations, stock adjustments, and the component/kit bill of materials (BOM). DynamoDB remains the order and checkout reservation store: its sellable-stock projection and atomic reservation guard are derived from InvenTree stock, with active reservations accounted for. Do not maintain independently editable physical quantities in both systems. Product descriptions, prices, and sellability remain in the catalog; map each sellable SKU and kit component to stable InvenTree part identifiers. Never infer a part from its display name.

Follow [Application architecture](application-architecture.md), [Backend API](backend-api.md), [Payment processing](payment-processing.md), [Infrastructure development workflow](infrastructure-development.md), and [Terraform conventions](terraform-conventions.md). Build the service in `infra/dev` using reusable modules in `infra/modules`, then promote the reviewed configuration to `infra/prod`. Do not create a separate Terraform root outside the repository's environment structure.

## Recommended VPC and Subnet Design

Use a dedicated VPC per environment in `us-west-2`. Select a CIDR that does not overlap existing VPCs, on-premises networks, VPN client pools, or peered networks. The following is an example address plan, not a fixed requirement:

| Subnet tier | Example CIDRs | Route/access purpose |
|---|---|---|
| Public, one subnet per AZ | `10.40.0.0/24`, `10.40.1.0/24` | Internet-facing egress only for NAT Gateways; no EC2 or RDS instances. |
| Private application, one subnet per AZ | `10.40.16.0/20`, `10.40.32.0/20` | EC2 application nodes, internal ALB nodes, and VPC-attached inventory Lambdas. Route outbound internet traffic through NAT when required. |
| Isolated database, one subnet per AZ | `10.40.64.0/24`, `10.40.65.0/24` | RDS subnet group only. No route to an Internet Gateway or NAT Gateway. |

Adjust CIDRs to fit the approved network plan. Keep at least two subnets in distinct Availability Zones for the RDS subnet group and load balancer. The database subnets must remain private even in dev.

### Traffic Flow

```text
Operator workstation
  -> AWS Client VPN (or approved SSM port-forward workflow)
  -> internal Application Load Balancer (HTTPS)
  -> EC2 private application nodes (InvenTree web / workers)
       -> RDS PostgreSQL in isolated database subnets
       -> S3 through a VPC gateway endpoint for media/static files

VPC-attached inventory Lambda security group
  -> internal ALB security group (HTTPS only)
  -> EC2 application security group (only the ALB target port)

EC2 application security group
  -> RDS security group (TCP 5432 only)
```

The ALB is internal: there is no public InvenTree hostname, public IP, or direct internet route to EC2/RDS. Provide staff access through AWS Client VPN with narrowly scoped authorization/routes and MFA through the chosen identity integration, or use SSM port forwarding for a very small operator group. Use private Route 53 DNS for the internal service name. Do not publish the InvenTree API to the storefront.

### Security Groups and Routes

- **ALB security group:** allow HTTPS from the Client VPN client CIDR and the inventory-integration Lambda security group only. If operators use SSM port forwarding directly to EC2 instead of the VPN/ALB path, omit that operator ingress path and keep the ALB limited to integration traffic.
- **EC2 security group:** allow the InvenTree reverse-proxy/application target port only from the ALB security group. Do not allow inbound SSH or public internet ingress. Manage instances with Systems Manager (SSM) Session Manager; use an instance profile with narrowly scoped SSM, logging, secret retrieval, and S3 access.
- **RDS security group:** allow PostgreSQL TCP 5432 only from the EC2 application security group. Do not allow access from the VPC CIDR generally, public addresses, Lambda security groups, or operator networks. Use separate application DB credentials with only the permissions InvenTree requires; reserve the master user for controlled administration.
- **Lambda security group:** allow egress to the internal ALB on HTTPS and to only required VPC endpoints/service destinations. Do not grant general inbound access to Lambda ENIs.
- **Network ACLs:** retain the default stateless ACL unless a documented requirement justifies custom rules; security groups provide the primary workload-level policy.
- **NAT and endpoints:** use NAT for required outbound access such as pulling pinned container images or reaching external update services. Production should use one NAT Gateway per AZ for resilience; a single NAT Gateway is a documented dev cost tradeoff. Add S3 gateway and appropriate interface endpoints (for example SSM, Secrets Manager, CloudWatch Logs, and SQS) where they reduce exposure/cost. Do not add an internet route to database subnets.

## Compute, Database, and Persistent Services

- **EC2:** run a supported, pinned InvenTree release using its documented container/process topology. Keep the instance in private application subnets with no public IP and attach an instance profile instead of static AWS access keys. Use an internal ALB with TLS from operators/Lambdas; encrypt the ALB-to-target hop where supported by the selected proxy configuration. Install updates through reviewed deployment automation, not ad hoc public SSH.
- **Dev size/availability:** a single EC2 instance and single-AZ RDS instance may be used to minimize cost, while retaining the private subnet/security-group boundaries. Document the resulting availability limits.
- **Production availability:** place EC2 nodes across at least two application subnets behind the internal ALB. Use an Auto Scaling Group or equivalent managed replacement process. Use Multi-AZ RDS. Ensure the selected InvenTree release and worker topology support the deployment model; run only one Celery beat scheduler unless the release explicitly supports leader election. Use a resilient supported broker such as managed ElastiCache Redis/Valkey for multi-node production, isolated in private subnets. A Redis process local to one EC2 node is acceptable only for a documented single-node dev configuration.
- **RDS PostgreSQL:** choose an engine version supported by the pinned InvenTree release. Place RDS in a DB subnet group spanning private database subnets, disable public accessibility, enforce TLS with certificate verification, enable encryption at rest and automated backups, and test point-in-time recovery/restore. Retrieve credentials from Secrets Manager; use managed master credentials where supported and a separate least-privilege application user. Never pass secret values through Terraform variables that persist in state.
- **Media and static files:** use a private, versioned S3 bucket and the EC2 instance profile. Prefer a supported InvenTree S3 storage integration for media; confirm the exact settings for the pinned release. Do not mount ephemeral instance storage as the only media copy. Restrict bucket access to the application role and required operators, and define lifecycle/retention and backup policies.
- **Secrets:** keep the InvenTree secret key, database credentials, and integration API token in environment-scoped Secrets Manager secrets. Deliver them to EC2 using a least-privilege instance role and the supported configuration mechanism. Do not place plaintext in user data, AMIs, Terraform state/plans, container definitions, committed `.env` files, or logs. Rotate credentials and test rotation procedures.
- **Operations:** emit system/application logs and health metrics to CloudWatch without customer data or credentials. Alert on unhealthy targets, EC2/disk pressure, failed workers, database storage/connections, stale inventory projection, and failed integration jobs. Back up RDS and media under a documented retention policy and test restore together into an isolated environment.

## Terraform and Network Implementation Sequence

1. Confirm the non-overlapping CIDR plan, operator access approach (Client VPN or SSM port forwarding), internal DNS name, dev/prod availability objectives, and InvenTree release/topology.
2. In `infra/modules`, add or reuse modules for VPC/subnets/routes/endpoints, security groups, EC2/instance profile, internal ALB, RDS, S3 media, secrets, and monitoring. Keep `project`, `environment`, and `tags` conventions and expose values through module outputs.
3. In `infra/dev`, create public, private application, and isolated database subnets across at least two AZs. Route only public subnets to the Internet Gateway; private application subnets use NAT/endpoints as needed; database subnet route tables have no internet route. Create the private RDS subnet group from isolated subnets.
4. Define security-group references rather than broad CIDR rules for ALB-to-EC2, EC2-to-RDS, and Lambda-to-ALB flows. Keep RDS non-public. Attach SSM and application permissions through separate least-privilege IAM roles.
5. Add DNS and internal TLS. Use ACM/private trust appropriate to internal clients; do not create a public endpoint solely to obtain a certificate or make service access easier. Ensure Lambda resolves the internal DNS name from the VPC.
6. Review the Terraform plan for public IPs, public RDS, broad ingress/egress, unintended NAT/database routes, plaintext secrets, resource replacement, and state impact. Run `terraform fmt` and `terraform validate`. Apply only with explicit operator authorization.
7. Deploy and validate the dev service, then promote the same intended configuration to prod with reviewed capacity, Multi-AZ database, NAT resilience, backup, alerting, and access settings.

Terraform examples must use the repository's provider/module conventions. Do not copy stand-alone Lightsail Terraform examples or create a second `inventree-aws/` root. Follow [Terraform conventions](terraform-conventions.md) and [Infrastructure development workflow](infrastructure-development.md); never run apply/destroy or AWS/state mutation without explicit authorization.

## InvenTree API and Data Contract

Implement the InvenTree client in `backend/shared` so inventory sync and stock-posting jobs use one authenticated, timeout-bounded integration. Put only the required inventory job Lambdas in the VPC and give them access to the internal ALB. Keep checkout/payment handlers outside the VPC unless they require private connectivity; this avoids forcing unrelated public payment API calls through NAT. If a checkout path must call InvenTree synchronously, document the reason and its NAT/endpoints needs, and prefer the durable job model below.

Give the integration service account only the InvenTree permissions required for reads and stock movements. Use API behavior verified against the pinned InvenTree release's docs/schema; do not guess endpoint names, payloads, or reservation semantics. Keep API tokens server-side. Bound retries and make non-idempotent requests safe.

Maintain an explicit SKU-to-part mapping with units of measure and kit BOM interpretation. Decide whether sellable stock is finished kits, components, or both; prevent double counting. Define eligible locations/states, excluding quarantined, damaged, or otherwise unavailable stock. Treat missing mappings, disabled parts, unexpected units, and insufficient stock as explicit errors, not zero stock or permission to substitute another part.

Maintain the DynamoDB projection and reservations as follows:

1. Synchronize eligible InvenTree quantities and BOM-derived availability into a versioned DynamoDB sellable-stock projection. A sync must not overwrite active checkout reservations. Compute availability from latest physical stock less active reservations, or use an equivalent atomic ledger preserving both. Record mapping, source revision/time, and last successful sync.
2. At checkout, reject stale/missing projections according to a configured freshness limit. Use a conditional DynamoDB transaction to reserve required stock and create the pending order. For component-based kits, reserve every required component atomically. Never trust client quantities, prices, or stock counts.
3. On verified payment, enqueue a durable InvenTree allocation/movement keyed idempotently by order and line item. After confirmed movement, retire that order's reservation exactly once as physical stock reduction enters the projection. Keep inventory-sync state separate from payment state; payment webhooks alone do not prove stock changed. Retry without duplicate movements, alert operators on unresolved failures, and reconcile.
4. On cancellation, failed payment, reservation expiry, or refunds/returns per business policy, release the DynamoDB reservation exactly once. Reverse/adjust an InvenTree movement only if one occurred and through a separate idempotent operation. Do not silently restock shipped goods on refund.

An order may be `paid` while inventory posting is pending; fulfillment must remain blocked until the movement succeeds or an operator resolves the failure. Test partial failure across order creation, provider requests, webhooks, stock movements, and reservation release. Do not claim a distributed transaction across DynamoDB, providers, and InvenTree.

Admin stock changes go through authorized backend operations that write physical stock in InvenTree. Each admin handler must enforce the `Admins` Cognito group. Do not expose a generic InvenTree proxy or directly edit the DynamoDB projection from an admin form. Audit actor, part, location, quantity, reason, and resulting movement, then reconcile the projection. Catalog reads use DynamoDB, not synchronous InvenTree calls.

## Reconciliation and Operations

Run scheduled, environment-specific reconciliation comparing eligible InvenTree physical stock/BOM availability with the DynamoDB projection, active reservations, completed orders, and pending inventory jobs. Automatically repair only well-defined projection drift. Report unknown mappings, duplicate movements, negative availability, stale syncs, and failed jobs for operator review. Record last-success timestamps and alert on aging projections and integration failures. Redact customer data, API tokens, and database credentials from logs.

Stage InvenTree upgrades in dev, pin the image/release, take and verify backups, run the supported database migration, and check API compatibility and worker processing before production promotion. Roll back the application only when schema compatibility is confirmed; otherwise use the tested database/media restore plan. Document health checks, credential rotation, alert response, and on-call recovery before production use.

## Implementation and Verification Checklist

1. Confirm the pinned InvenTree release, EC2 process topology, broker, S3 media support, RDS version/TLS, secret injection, VPC CIDRs, internal access path, and Lambda-to-ALB connectivity before building dependent code.
2. Build dev networking and service resources. Review security groups, route tables, public exposure, secret flow, and Terraform plans. Run format/validation; do not apply without operator authorization.
3. Deploy the dev application and verify internal DNS/TLS, Client VPN or SSM operator access, SSM management without SSH ingress, private RDS connectivity, media persistence, worker processing, alarms, and backup/restore.
4. Implement mappings, sync, reservation-aware projection, idempotent stock jobs, admin writes, and reconciliation. Update [Backend API](backend-api.md), [Payment processing](payment-processing.md), and the DynamoDB data model when contracts change.
5. Test component and finished-kit stock without double counting, concurrent last-unit checkout, stale projection rejection, InvenTree downtime, failed/duplicate/out-of-order payment events, cancellation, retry after partial movement, and reconciliation after admin adjustment.
6. Validate the entire dev path from InvenTree stock to catalog availability, checkout reservation, verified payment, physical movement, reservation retirement, failure alerts, and restore. Promote only the reviewed equivalent to prod via [Infrastructure development workflow](infrastructure-development.md).

Never use production inventory or credentials to validate dev.