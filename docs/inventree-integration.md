# InvenTree Inventory Integration

## Goal and Boundaries

Run InvenTree on Amazon EC2 with Amazon RDS for PostgreSQL. Each environment has one VPC, shared only by InvenTree, its operator jumpbox and NAT instance, and the VPC-attached inventory Lambdas. This is the intended deployment architecture for both dev and prod. The storefront and admin applications continue to use API Gateway and Python Lambda; browsers must not call InvenTree or receive its API credentials.

InvenTree owns physical stock, locations, stock adjustments, and the component/kit bill of materials (BOM). DynamoDB remains the order and checkout reservation store: its sellable-stock projection and atomic reservation guard are derived from InvenTree stock, with active reservations accounted for. Do not maintain independently editable physical quantities in both systems. Product descriptions, prices, and sellability remain in the catalog; map each sellable SKU and kit component to stable InvenTree part identifiers. Never infer a part from its display name.

Follow [Application architecture](application-architecture.md), [Backend API](backend-api.md), [Payment processing](payment-processing.md), [Infrastructure development workflow](infrastructure-development.md), and [Terraform conventions](terraform-conventions.md). Build the service in `infra/dev` using reusable modules in `infra/modules`, then promote the reviewed configuration to `infra/prod`. Do not create a separate Terraform root outside the repository's environment structure.

The hosting design below was resolved on 2026-09-28 against InvenTree **1.5.6** source and current AWS documentation and pricing. It is proposed design: none of these resources exist until they are implemented in `infra/` and applied with explicit operator authorization.

## Selected Architecture

```text
Windows 11 laptop --aws sso login (Identity Center + MFA)--> SSM port-forward (no inbound ports)
   --> mstsc localhost:13389 --> Windows jumpbox (private-app) -- Edge --+
Inventory Lambdas (sync/jobs, private-app ENIs) ------------------------+
                                                                        v  HTTPS 443, private DNS
        inventree.vitamin-packs.com (prod) / inventree.dev.vitamin-packs.com (dev)
        -> EC2 Auto Scaling group of one (private-app):
           Caddy (Let's Encrypt via Route 53 DNS-01) -> gunicorn | django-q2 worker
             |-- TCP 5432, TLS verify-full --> RDS PostgreSQL 17 (DB subnets, local-only route)
             |-- S3 gateway endpoint --> media bucket, artifacts bucket, AL2023 repos, ECR layers
             '-- TCP 443 via NAT instance (public subnet) --> SSM, Secrets Manager, ECR, Logs, SES, Route 53, ACME
```

The design is sized for one staff user, a prod hosting budget under $50/month, and a recovery time and recovery point measured in hours. It deliberately has no load balancer, no NAT gateway, no interface endpoints, and no Multi-AZ database. Revisit those choices only with an explicit budget or availability change (see [Scale-Out Path](#scale-out-path)).

## VPC

Use one VPC per environment in `us-west-2`. It holds only the InvenTree host, the operator jumpbox, the NAT instance, RDS, and the inventory Lambdas that need InvenTree. The rest of the application (API Gateway, other Lambdas, DynamoDB, CloudFront) is serverless and stays outside any VPC, so there is no wider application VPC to share.

A single VPC keeps security-group references between the Lambdas, the jumpbox, and the host. It also avoids peering or Transit Gateway and leaves one owner for the route tables: the `network` module. Add future private workloads as subnets and security groups in this VPC. If a peered VPC is ever needed, same-Region peering still supports security-group references.

## Subnets, Routes and Egress

The owner approved these CIDRs. Each environment has four public /22s and four private /22s. Each private /22 is split into an application /23 and an isolated database /23 in the same AZ. AZs a and b are active; c and d are created but unused.

| AZ (ID) | Status | dev public | dev app | dev DB | prod public | prod app | prod DB |
|---|---|---|---|---|---|---|---|
| a (usw2-az2) | active | 192.168.0.0/22 | 192.168.16.0/23 | 192.168.18.0/23 | 192.168.32.0/22 | 192.168.48.0/23 | 192.168.50.0/23 |
| b (usw2-az1) | active | 192.168.4.0/22 | 192.168.20.0/23 | 192.168.22.0/23 | 192.168.36.0/22 | 192.168.52.0/23 | 192.168.54.0/23 |
| c (usw2-az3) | reserved | 192.168.8.0/22 | 192.168.24.0/23 | 192.168.26.0/23 | 192.168.40.0/22 | 192.168.56.0/23 | 192.168.58.0/23 |
| d (usw2-az4) | reserved | 192.168.12.0/22 | 192.168.28.0/23 | 192.168.30.0/23 | 192.168.44.0/22 | 192.168.60.0/23 | 192.168.62.0/23 |

- The dev VPC is `192.168.0.0/19` and the prod VPC is `192.168.32.0/19`.
- **Pin subnets by AZ ID, not AZ letter.** Letter-to-ID mapping differs per account; the IDs above are this account's.
- There is no overlap with the account's existing VPCs (`172.32.0.0/16` and the default `172.31.0.0/16`).
- `192.168.x` overlaps typical home LANs. That is harmless with SSM tunnelling, but it rules out a future site-to-site VPN or Client VPN without readdressing.
- Treat any CIDR change as destructive.

Route tables:

| Route table | Routes | Used by |
|---|---|---|
| Public (shared) | `local`; `0.0.0.0/0` → internet gateway | NAT instance only |
| App a, app b | `local`; `0.0.0.0/0` → NAT instance ENI; S3 and DynamoDB gateway endpoints | InvenTree host, jumpbox, inventory Lambdas |
| App c, app d | `local`; S3 and DynamoDB gateway endpoints; no default route | reserved |
| DB (shared) | `local` only | RDS subnet group |

Only the NAT instance has a public IP. RDS never has an internet route.

**Why a NAT instance.** A t4g.nano NAT instance costs about $7.36/month, including its public IPv4 address. A NAT gateway costs about $32.85/month, and the seven interface endpoints the private hosts would otherwise need cost about $51/month in one AZ. A regional NAT gateway is billed per active AZ, so it saves nothing. One NAT cannot be shared across the dev and prod VPCs cheaply: peering does not transit through a NAT, and Transit Gateway attachments cost more than a NAT. Within each VPC, both active application route tables share the single NAT instance.

NAT instance:
- Auto Scaling group of one across public subnets a and b.
- Latest Amazon Linux 2023 arm64 AMI, t4g.nano.
- Auto-assigned public IPv4 rather than an Elastic IP, so there is no charge while it is stopped.
- Boot script:
  - Disables the source/destination check on the instance.
  - Enables IP forwarding and nftables masquerade.
  - Calls `ec2:ReplaceRoute` to point `0.0.0.0/0` in the app a/b route tables at its own ENI.
  - Its IAM role is scoped to those route tables and to the instance itself.
- Patched by monthly instance refresh.
- If it fails, only egress stops: inventory sync and jobs, SSM access, ECR pulls, email, and certificate renewal. Checkout keeps working from the DynamoDB projection until parts exceed the [freshness limit](#sync-and-freshness) (20 minutes), then fails closed for those parts. An alarm fires when the NAT group is unhealthy.

Egress controls:
- Private security groups allow outbound traffic only on TCP 443, plus PostgreSQL to RDS from the host and the gateway-endpoint prefix lists.
- The NAT security group accepts TCP 443 only from the host, jumpbox, and inventory-Lambda security groups.
- The S3 gateway endpoint policy allows only:
  - the environment's media and artifacts buckets;
  - `al2023-repos-us-west-2-de612dc2`, for Amazon Linux packages without internet access;
  - `prod-us-west-2-starport-layer-bucket`, for ECR image layers.
- The DynamoDB gateway endpoint policy allows only the application table.
- Keep the default network ACLs. Security groups are the workload-level policy.

InvenTree 1.5.6 makes only two outbound internet calls by default: daily exchange rates from `api.frankfurter.app` and a weekly GitHub update check. Turn both off during setup, since the store is USD-only:
- `CURRENCY_UPDATE_INTERVAL=0`
- `INVENTREE_UPDATE_CHECK_INTERVAL=0`

## Staff Access

Staff reach the InvenTree UI through a Windows Server jumpbox inside the VPC. The laptop connects with native Remote Desktop over an AWS Systems Manager port-forwarding session, so there are no inbound ports, no VPN, and no public InvenTree endpoint. Step-by-step operator instructions are in the [README](../README.md#staff-access-to-inventree-windows-jumpbox).

Jumpbox instance:
- Latest AWS-provided Windows Server 2025 AMI, from the SSM public parameter. t3.small.
- Auto Scaling group across app subnets a and b.
- No public IP, no key pair, IMDSv2 required, encrypted 30 GB gp3 root.
- **Desired capacity is 0 by default, with no schedule.**
  - The owner starts it in the console when needed and returns it to 0 afterwards.
  - The instance is stateless and its root volume is deleted on termination, so an idle jumpbox costs nothing.
  - A CloudWatch alarm on the group's `GroupInServiceInstances` sends an email reminder after 8 hours in service. Enable Auto Scaling group metrics for this.
- Patching: every launch uses the latest AMI, and a monthly instance refresh covers any long-running instance. There is no Windows Update.
- Instance role:
  - `AmazonSSMManagedInstanceCore` and the CloudWatch agent policy.
  - `secretsmanager:GetSecretValue` on the jumpbox login secret only.
  - `ssm:PutParameter` on `/<project>/<env>/jumpbox/rdp-thumbprint` only. The instance publishes its RDP certificate thumbprint there at boot.

Connection:
- **Primary:**
  1. On the laptop, run `aws sso login`.
  2. Start `aws ssm start-session` with document `AWS-StartPortForwardingSession`, forwarding local port 13389 to the jumpbox's port 3389.
  3. Connect `mstsc` to `localhost:13389`.
- **Fallback:** Fleet Manager Remote Desktop in the AWS console, using **User credentials** with the same Windows account. Never use its IAM Identity Center sign-in option: that creates a persistent local Administrator account on the instance. Fleet Manager sessions end after 60 minutes (renewable) or 10 idle minutes, and support text clipboard only, with no file transfer.

Identity and MFA, in three layers:
1. **AWS:** IAM Identity Center with MFA enforced. The permission set `inventree-<env>-operator` allows only:
   - `ssm:StartSession` on the tagged jumpbox with the port-forwarding document;
   - `ssm:TerminateSession` on the user's own sessions;
   - `ssm-guiconnect:StartConnection`, `GetConnection`, and `CancelConnection`, for the fallback;
   - `secretsmanager:GetSecretValue` on the jumpbox login secret;
   - `ec2:DescribeInstances` and `autoscaling:Describe*`;
   - `autoscaling:SetDesiredCapacity` and `autoscaling:UpdateAutoScalingGroup` on the jumpbox group only.
2. **Windows:** one local non-admin user, `inventree-operator`, in Remote Desktop Users.
   - Launch user data (which contains no secrets) creates or updates it from the Secrets Manager secret `<project>-<env>-jumpbox-login`.
   - Terraform creates only the secret container; the value is set out of band and never enters Terraform state.
   - The Administrator password is not retrievable. Administrative work uses SSM Run Command.
3. **InvenTree:** local InvenTree accounts with the `LOGIN_ENFORCE_MFA` global setting enabled.

Egress from the jumpbox:
- The SSM agent must reach public SSM endpoints over TCP 443 through the NAT instance, so the security group cannot block browsing on its own. The owner accepted this tradeoff.
- Windows Defender Firewall denies all outbound traffic by default and allows only:
  - the SSM agent and session worker;
  - the CloudWatch agent;
  - EC2Launch;
  - DNS to the VPC resolver;
  - **Edge to the VPC CIDR only.**
- The non-admin user cannot change these rules.

File transfer:
- InvenTree runs inside the jumpbox's browser, so files move through RDP drive redirection.
- The laptop maps one dedicated folder to a `subst` drive (`T:`) and redirects only that drive.
- This carries uploads (part images, datasheets, invoices, CSV/XLSX imports, label templates) and downloads (exports, PDF reports and labels).
- Verify during dev acceptance that `subst` drives appear in the `mstsc` drive list.
- Rejected alternatives:
  - an S3 transfer bucket (too many steps per file);
  - an upload route in the admin app (it becomes a generic InvenTree proxy, which is prohibited);
  - giving the jumpbox general internet access.

Audit:
- CloudTrail records `StartSession` and `StartConnection` events.
- The CloudWatch agent forwards Windows Security logon events 4624 and 4625.
- Caddy access logs and InvenTree's own login records identify the user.
- Session Manager does not record the contents of port-forwarding sessions. With a single staff user, RDP session recording is not required.

InvenTree host administration uses SSM Session Manager shell sessions with session logging. SSM port forwarding to the host is break-glass only. There is no SSH anywhere.

## InvenTree Host

### Process Topology

Run InvenTree **1.5.6**, pinned by image digest (`inventree/inventree:1.5.6@sha256:…`).

Host:
- One Amazon Linux 2023 arm64 host in an Auto Scaling group of one across app subnets a and b.
- Instance size: **t4g.small** (2 GiB) in dev and **t4g.medium** (4 GiB) in prod. Covering prod with a one-year EC2 Instance Savings Plan is a prod go-live gate (see [Dev vs Prod and Cost](#dev-vs-prod-and-cost)).
- 20 GB gp3 root and a 1 GiB swap file.
- Docker, the CloudWatch agent, and the SSM agent come from Amazon Linux repositories through the S3 gateway endpoint.

Containers:

| Container | Command | Role |
|---|---|---|
| `inventree-server` | gunicorn | Web and API. `INVENTREE_GUNICORN_WORKERS=2`; the default of CPU×2+1 is too many for the memory. |
| `inventree-worker` | `invoke worker` | Background tasks and scheduled tasks, as a django-q2 cluster. |
| `caddy` | Caddy, custom-built with the `caddy-dns/route53` module | TLS on 443; serves static files and proxies to gunicorn. |

InvenTree uses **django-q2**, not Celery:
- **Broker:** the task queue lives in PostgreSQL. InvenTree configures django-q2's ORM broker, which takes precedence over Redis even when a cache is configured.
- **Scheduler:** it runs inside the worker cluster and claims due schedules with row locks.
- **No Redis:** without Redis, InvenTree uses a per-process local-memory cache and limits the worker to one thread. That is correct for a single node and saves memory.

Build and mirror images in CI outside the VPC:
- Push the InvenTree digest and the custom Caddy build to environment ECR repositories.
- Hosts pull through the NAT instance and the S3 gateway endpoint.
- Never use mutable `latest` or `stable` tags.

Configuration:
- `INVENTREE_SITE_URL`: `https://inventree.vitamin-packs.com` (prod) or `https://inventree.dev.vitamin-packs.com` (dev).
- Explicit `INVENTREE_ALLOWED_HOSTS` and `INVENTREE_TRUSTED_ORIGINS`.
- `INVENTREE_AUTO_UPDATE=false`, so migrations never run implicitly.
- Secret key and OIDC key via `INVENTREE_SECRET_KEY_FILE` and `INVENTREE_OIDC_PRIVATE_KEY_FILE`, written to tmpfs at boot from Secrets Manager. They must stay constant across host replacements; otherwise InvenTree generates new ones and invalidates sessions and tokens.
- Deliver secrets through the instance role. Never put them in user data, AMIs, Terraform state, container definitions, committed `.env` files, or logs.

### TLS and Private DNS

There is no load balancer. Caddy terminates TLS on the host with a **Let's Encrypt** certificate obtained by DNS-01:
- It writes only the `_acme-challenge.<fqdn>` TXT record in the existing public `vitamin-packs.com` hosted zone.
- IAM conditions `route53:ChangeResourceRecordSetsNormalizedRecordNames`, `RecordTypes`, and `Actions` limit it to that name and type.
- Terraform reads the public zone with a data source and never imports or manages it.
- The public zone has no A record for either InvenTree hostname, so InvenTree is not reachable from the internet.
- Clients need no custom trust store. Lambda (certifi) and Edge trust the Let's Encrypt roots.
- The hostnames appear in Certificate Transparency logs. The owner accepted this. There is no AWS Private CA.
- After each issuance or renewal, the host copies Caddy's certificate storage to the artifacts bucket and restores it at boot. This keeps host replacements under Let's Encrypt's limit of five duplicate certificates per seven days.

Private DNS:
- Each environment has a Route 53 **private hosted zone whose apex is exactly the InvenTree hostname**, associated only with that environment's VPC:
  - prod: `inventree.vitamin-packs.com`
  - dev: `inventree.dev.vitamin-packs.com`
- Never create a private zone named `vitamin-packs.com`. The VPC resolver would return NXDOMAIN for every name missing from it, breaking mail and other `vitamin-packs.com` lookups inside the VPC.
- At boot, the host UPSERTs the zone's apex A record to its own private IP with a 60-second TTL. IAM limits it to that zone, name, record type, and UPSERT.
- The InvenTree client in `backend/shared` retries connection errors so it tolerates the TTL window after a replacement.

### Email

InvenTree administration email (password resets, notifications) goes through the Amazon SES API with the instance role. There are no SMTP credentials and no IAM user keys.

InvenTree 1.5.6 bundles `django-anymail[amazon-ses]`. Configure:
- `INVENTREE_EMAIL_BACKEND=anymail.backends.amazon_ses.EmailBackend`
- `INVENTREE_ANYMAIL={"AMAZON_SES_CLIENT_PARAMS":{"region_name":"us-west-2"}}`
- `INVENTREE_EMAIL_SENDER=inventree@vitamin-packs.com` in prod, or `inventree-dev@vitamin-packs.com` in dev.

IAM allows `ses:SendEmail` and `ses:SendRawEmail` on the `vitamin-packs.com` identity only, with a `ses:FromAddress` condition for the environment's sender. Confirm the exact action set in dev.

SES identity:
- A domain identity for `vitamin-packs.com` with Easy DKIM, in the `ses-identity` module, one per account.
- Terraform adds the three DKIM CNAME records to the existing public zone. It leaves the existing Google Workspace MX, SPF, and DKIM records untouched.
- DMARC alignment comes from DKIM; there is no custom MAIL FROM domain.
- Recipients are addresses at the verified domain, so the account can remain in the SES sandbox (200 messages per day).

### Health, Deployment and Persistence

Health:
- A systemd timer on the host calls `https://localhost/api/system/health/` and `invoke worker-health`, which checks the worker heartbeat, and publishes the results as a CloudWatch metric.
- After three consecutive failures it marks its own instance unhealthy with `autoscaling:SetInstanceHealth`, so the group replaces it.
- The group also uses EC2 status checks.
- Alarms go to an SNS topic with an email subscription for the owner.

Persistence: nothing authoritative lives on the host.
- The database is in RDS and media is in S3.
- Secrets are in Secrets Manager; static files are rebuilt from the image.
- The Caddy certificate is backed up to S3, and logs go to CloudWatch.
- Replacing the instance loses nothing.

Upgrade procedure (stage every upgrade in dev first):
1. Take a manual RDS snapshot, and confirm S3 media versioning is on.
2. Stop the worker container.
3. Run a one-off `invoke migrate` container through SSM Run Command. This is the only place migrations run. Use `--skip-backup` semantics; the RDS snapshot is the backup, and the image's `pg_dump` must match the PostgreSQL major version.
4. Start an Auto Scaling instance refresh (minimum healthy 0%) to the launch template with the new image digest.
5. Smoke-test the UI, the API, the worker heartbeat, and an inventory-sync run.
6. Check API compatibility for the inventory Lambdas before promoting to prod.

The site is down for a few minutes during a refresh. That is acceptable because checkout reads the DynamoDB projection and never calls InvenTree synchronously. The outage must stay inside the 20-minute [freshness limit](#sync-and-freshness).

Roll back the application image only when the schema is still compatible. Otherwise use the [restore procedure](#rds-postgresql).

### Scale-Out Path

Scale-out is documented, not built. If InvenTree ever needs more than one web node:
1. Put an internal ALB in front of two or more web instances.
2. Run a separate worker group of one.
3. Add a shared cache.

Preconditions:
- InvenTree 1.5.6 builds only plaintext `redis://` cache URLs, so a managed cache needs a TLS tunnel or a newer release that supports TLS.
- The prod budget must increase.
- Without a shared cache, multiple web nodes would each keep separate local-memory caches.

## RDS PostgreSQL

- **Engine:** PostgreSQL **17**, latest 17.x minor. This matches InvenTree's reference container database and the `pg_dump` client in its image.
- **Instance:** db.t4g.micro, **single-AZ** in both environments, with 20 GB gp3 storage.
- **Encryption:** AWS-managed KMS key.
- **Network:** not publicly accessible. The DB subnet group uses DB subnets a and b.
- **Maintenance:** automatic minor version upgrades off; minor and major upgrades are staged in dev first.
- **TLS:** a custom parameter group sets `rds.force_ssl=1`. It is already the default on PostgreSQL 15 and later; set it explicitly so it can't regress.
  - InvenTree connects with `INVENTREE_DB_OPTIONS={"sslmode":"verify-full","sslrootcert":"/etc/ssl/rds/global-bundle.pem"}`.
  - The RDS CA bundle comes from the artifacts bucket.
- **Credentials:**
  - The master user password is RDS-managed in Secrets Manager and is used only for administration and bootstrap.
  - A separate `inventree_app` login owns only the `inventree` database and is not a superuser. Its credentials live in the InvenTree Secrets Manager secret.
- **Backups:** automated backups with point-in-time recovery, 7-day retention.
  - Prod has deletion protection and a final snapshot on delete.
  - Recovery point is about 5 minutes; RDS uploads transaction logs every five minutes.
  - Recovery time is measured in hours: there is no automatic failover. The owner accepted this for cost.

Restore procedure (rehearse it in dev each quarter and before prod upgrades):
1. Restore to a point in time or from a snapshot as a **new** DB instance, using the same subnet group, security group, and parameter group.
2. Restore S3 media objects to the same timestamp from object versions.
3. Update the SSM parameter that holds `INVENTREE_DB_HOST`.
4. Start an Auto Scaling instance refresh of the InvenTree host.
5. Validate the UI, the API, and inventory reconciliation, then retire the old instance.

## Media and Artifacts

Media bucket (one per environment):
- Private, versioned, SSE-S3, Block Public Access on.
- InvenTree configuration:
  - `INVENTREE_STORAGE_TARGET=s3`
  - `INVENTREE_S3_BUCKET_NAME=<bucket>`
  - `INVENTREE_S3_REGION_NAME=us-west-2`
  - `INVENTREE_S3_ENDPOINT_URL=https://s3.us-west-2.amazonaws.com` (required: InvenTree builds its media URL from it)
  - No access keys; boto3 uses the instance role.
- Bucket policy denies non-TLS requests and denies all object access unless `aws:SourceVpce` is this VPC's S3 gateway endpoint.
- This works because InvenTree serves media as presigned S3 URLs that the browser fetches directly. The only browser is on the jumpbox, whose S3 route is the gateway endpoint.
- Noncurrent object versions expire after 7 days, matching RDS backup retention.

Artifacts bucket (one per environment):
- Holds the pinned Docker Compose binary and checksum, the RDS CA bundle, and the Caddy certificate backup.
- Same controls as the media bucket.

The backup and restore scope is RDS, S3 media versions, and the Secrets Manager secrets. Keep the InvenTree secret key and OIDC key: losing them logs everyone out and invalidates issued tokens.

## Security Groups

| Security group | Inbound | Outbound |
|---|---|---|
| `jumpbox` | none | TCP 443 → `inventree`; TCP 443 → `0.0.0.0/0` via NAT (the host firewall limits this to the SSM and CloudWatch agents); TCP 443 → S3 prefix list |
| `inventree` (EC2 host) | TCP 443 from `jumpbox` and `inv-lambda` | TCP 5432 → `rds`; TCP 443 → `0.0.0.0/0` via NAT; TCP 443 and 80 → S3 prefix list |
| `rds` | TCP 5432 from `inventree` | none |
| `inv-lambda` | none | TCP 443 → `inventree`; TCP 443 → `0.0.0.0/0` via NAT (Secrets Manager, SQS); TCP 443 → DynamoDB prefix list |
| `nat` | TCP 443 from `jumpbox`, `inventree`, and `inv-lambda` | TCP 443 → `0.0.0.0/0` |

- Use security-group references wherever a peer is a security group.
- The RDS security group never allows the VPC CIDR, Lambda, the jumpbox, or any operator network.
- Neither the InvenTree host nor the jumpbox has an inbound port open to operators. Both are reached only through SSM.
- There is no SSH or RDP ingress anywhere.
- Operators have no network path to RDS. Database administration runs on the InvenTree host through SSM.

## Dev vs Prod and Cost

| | dev (on-demand) | prod (always on) |
|---|---|---|
| Hostname | `inventree.dev.vitamin-packs.com` | `inventree.vitamin-packs.com` |
| InvenTree host | t4g.small on-demand, group of 0 or 1 | t4g.medium on the Savings Plan, group of 1 |
| RDS | db.t4g.micro single-AZ, stopped when idle | db.t4g.micro single-AZ |
| NAT instance | group of 0 or 1 | group of 1 |
| Jumpbox | 0 or 1, started manually | 0 or 1, started manually, with an 8-hour reminder alarm |
| Email sender | `inventree-dev@vitamin-packs.com` | `inventree@vitamin-packs.com` |
| Inventory sync schedule | disabled; run manually | enabled |

Dev runs only when needed:
- A nightly EventBridge Scheduler job, using universal targets, sets the dev Auto Scaling groups to 0 and stops the DB instance. It also handles the automatic restart RDS performs after seven days stopped.
- Starting dev is a deliberate operator action, in this order: RDS, then the NAT instance, then the InvenTree host, then the jumpbox.
- A dev-only start script under `scripts/` is planned. It must follow the [deployment-script rules](infrastructure-development.md#deployment-scripts).

**Prod estimate, per month.** Prices are us-west-2 on-demand from the AWS Pricing API (September 2026), 730 hours per month; "est." items are estimates.

| Item | $/month |
|---|---|
| InvenTree host: t4g.medium on a one-year no-upfront EC2 Instance Savings Plan ($0.0211/h), plus 20 GB gp3 | 15.40 + 1.60 |
| RDS db.t4g.micro single-AZ, plus 20 GB gp3 | 11.68 + 2.30 |
| NAT instance: t4g.nano, 8 GB gp3, public IPv4 | 3.07 + 0.64 + 3.65 |
| Jumpbox: t3.small Windows, about 20 hours a month | ~0.80 |
| Secrets Manager: four secrets | 1.60 |
| Route 53 private hosted zone | 0.50 |
| CloudWatch logs, alarms, and metrics (est.) | ~1.50 |
| SES, S3, and data transfer (est.) | ~0.40 |
| **Total** | **≈ 43** |

- **Buy the t4g-family EC2 Instance Savings Plan before prod go-live.** It is a billing commitment, bought in the console, not in Terraform. Without it the t4g.medium costs $0.0336/h on demand and the total rises to about $52, over the $50 budget. The plan applies to any t4g size in the Region.
- **Dev:** about $4.40/month idle (RDS storage, secrets, private zone), plus about $0.08 per running hour.
- Check the prod run rate in Cost Explorer after the first full week. Confirm that Savings Plan utilization is near 100%.

## Secret Rotation

| Secret | Used by | Cadence | Method | Impact |
|---|---|---|---|---|
| RDS master password | administration and bootstrap only | Every 7 days, automatic | RDS-managed secret | None; InvenTree never uses it |
| `inventree_app` database password | InvenTree containers | Every 90 days, and immediately on suspected exposure | Scripted manual rotation (below) | About one minute of downtime |
| InvenTree integration API token | Inventory Lambdas | Every 90 days | Overlap rotation using InvenTree token expiry (below) | None |
| Jumpbox Windows password | The staff user | Monthly | Put a new secret version; the next jumpbox launch applies it | None |
| InvenTree secret key and OIDC key | InvenTree | Only on compromise | New secret value, then container restart | Logs out all sessions and invalidates OIDC tokens: 1.5.6 has no secret-key fallback |
| TLS certificate | Caddy | About every 60 days, automatic | Let's Encrypt renewal by DNS-01 | None |
| Identity Center password and MFA | The staff user | Identity Center policy | Identity Center | None |

**Why the database password is rotated manually.** A Secrets Manager rotation Lambda would need its own network path to RDS, breaking the rule that only the InvenTree host reaches the database. Single-user rotation also changes the password under the running application, which needs a restart anyway. Alternating-user rotation avoids the restart but needs a shared owner role, so that objects created by Django migrations stay usable by both logins. That design isn't worth it for one user and an hours-level recovery objective.

Database password rotation runbook (SSM Run Command on the InvenTree host):
1. Generate a new password.
2. Using the RDS-managed master secret, run `ALTER ROLE inventree_app PASSWORD …`.
3. Put the new password as a new version of the InvenTree secret.
4. Restart the InvenTree containers so they read the new secret.
5. Check `/api/system/health/` and a login, then record the rotation.

Integration token overlap procedure:
1. In InvenTree, create a new API token for the integration user, with an expiry about 100 days out.
2. Put it as a new version of the integration-token secret. The Lambdas cache the secret for five minutes and re-read it on HTTP 401.
3. After 24 hours, revoke the old token in InvenTree.

## Terraform Modules and Prerequisites

Implement these reusable modules in `infra/modules` and compose them through an `inventree` orchestrator module in `infra/dev`, then `infra/prod`. Keep the `project`, `environment`, and `tags` conventions, and connect modules through outputs.

| Module | Key outputs |
|---|---|
| `network`: VPC, subnets, internet gateway, route tables, S3 and DynamoDB gateway endpoints and their policies | `vpc_id`, `public_subnet_ids`, `private_app_subnet_ids`, `db_subnet_ids`, `private_app_route_table_ids`, `s3_prefix_list_id`, `dynamodb_prefix_list_id` |
| `nat-instance` | `nat_asg_name`, `nat_security_group_id` |
| `inventree-security-groups` | `inventree_sg_id`, `rds_sg_id`, `inventory_lambda_sg_id`, `jumpbox_sg_id` |
| `route53-private-zone`, plus a data source for the existing public zone | `private_zone_id`, `inventree_fqdn` |
| `ecr`: InvenTree image and custom Caddy build | `repository_urls` |
| `s3-media`, `s3-artifacts` | bucket names and ARNs |
| `secrets`: containers only; values set out of band | `inventree_app_secret_arn`, `integration_token_secret_arn`, `jumpbox_login_secret_arn` |
| `ec2-asg`: InvenTree host, instance role with scoped Route 53 and SES permissions, health reporting | `inventree_asg_name`, `inventree_role_arn` |
| `rds-postgres` | `db_endpoint`, `db_instance_id`, `master_user_secret_arn` |
| `windows-jumpbox` | `jumpbox_asg_name`, `jumpbox_role_arn` |
| `monitoring`: SNS topic with an email subscription to `var.alert_email`, plus alarms | `alerts_topic_arn` |
| `ses-identity`: domain identity and DKIM records, one per account | `ses_identity_arn` |
| `dev-scheduler`: dev only | `schedule_arns` |

The backend consumes `private_app_subnet_ids`, `inventory_lambda_sg_id`, `inventree_fqdn` (the InvenTree base URL), and `integration_token_secret_arn`. See [Backend API](backend-api.md#private-inventree-connectivity).

Prerequisites. Account state was verified read-only on 2026-09-28:
- **Done:**
  - Public hosted zone `vitamin-packs.com` exists.
  - IAM Identity Center is enabled in `us-west-2` with MFA enforced.
  - CloudTrail is enabled.
- **Service quotas:** all at defaults, and no increase is needed.
  - Elastic IPs: 0 used; the NAT instance uses an auto-assigned address.
  - VPCs per Region: 4 of 5 after both environments exist. Request more before adding another VPC.
  - On-demand standard vCPUs: 1920.
  - Lambda concurrency: 1000.
  - Fleet Manager concurrent connections: 5.
- **To do:**
  - Remote-state bootstrap.
  - A CI job that mirrors the pinned InvenTree digest and builds the Caddy image into ECR.
  - Set the SNS alert address (`larryj@vitamin-packs.com`) and confirm the subscription email.
  - Buy the Savings Plan before prod go-live.

Review every plan for public IPs other than the NAT instance, public RDS, broad ingress, unintended default routes on the DB or reserved subnets, plaintext secrets, resource replacement, and state impact. Run `terraform fmt` and `terraform validate`. Apply only with explicit operator authorization. Do not copy stand-alone Lightsail examples or create a second Terraform root. Never run apply, destroy, or state or AWS mutation without explicit authorization.

## Acceptance Tests

Run these in dev before promoting, and again in prod before go-live.

- **Network:**
  - The DB route table has only the `local` route, and the reserved app route tables have no default route.
  - Only the NAT instance has a public IP.
  - An S3 request from the jumpbox to a bucket outside the endpoint policy is denied.
- **Egress:**
  - Edge on the jumpbox cannot load any public site, while the SSM tunnel works.
  - InvenTree makes no calls to `api.frankfurter.app` or GitHub.
- **TLS and DNS:**
  - Lambda and Edge validate the Let's Encrypt certificate with default trust.
  - After an instance refresh, the private record points to the new host within 60 seconds and the certificate is restored from S3 without a new issuance.
- **Jumpbox:**
  - Following the README exactly, connect as the non-admin user, upload a laptop file as a part image through the redirected drive, and copy a CSV export back.
  - The Fleet Manager fallback works with User credentials, and no Identity Center-created admin account exists.
  - A user without the permission set cannot start a session.
  - The 8-hour reminder alarm fires.
- **RDS:**
  - `pg_stat_ssl` shows `ssl = t` for InvenTree connections, and a connection with `sslmode=disable` is rejected.
  - A point-in-time restore rehearsal completes and InvenTree starts against the restored instance.
- **Worker and health:**
  - Stopping the worker raises the heartbeat alarm.
  - A host that fails health checks is replaced.
  - Scheduled tasks run once per interval.
- **Media:**
  - An upload lands in S3 and survives an instance replacement.
  - A versioned restore works.
  - Object access from outside the gateway endpoint is denied.
- **Email:**
  - An InvenTree test email reaches `larryj@vitamin-packs.com` with DKIM passing.
  - No SMTP credentials exist.
- **Rotation:**
  - The database-password runbook completes with only a restart.
  - Integration-token overlap rotation causes no Lambda failures.
- **Dev on demand:**
  - The nightly stop leaves only storage running.
  - The start sequence brings dev up in order.
- **Cost:** the prod run rate is under $50/month after one full week, with the Savings Plan covering the t4g.medium hours.

## Open Owner Actions

All design decisions are resolved. Remaining owner actions:
1. Buy the one-year t4g EC2 Instance Savings Plan before prod go-live.
2. Confirm the SNS email subscription.
3. Change the sender addresses if `inventree@` and `inventree-dev@` are not wanted.

## References

- InvenTree 1.5.6 source, tag `1.5.6`:
  - `contrib/container/docker-compose.yml`, `Caddyfile`, `gunicorn.conf.py`
  - `src/backend/InvenTree/InvenTree/setting/worker.py`, `setting/storages.py`, `setting/db_backend.py`, `cache.py`, `settings.py`
  - `src/backend/InvenTree/common/setting/system.py`
  - `src/backend/requirements.txt`
  - django-q2 1.10.0 `brokers/__init__.py` and `scheduler.py`
- InvenTree documentation: [Docker](https://docs.inventree.org/en/stable/start/docker/), [Configuration](https://docs.inventree.org/en/stable/start/config/), [Processes](https://docs.inventree.org/en/stable/start/processes/)
- Amazon RDS: [SSL with PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html), [Point-in-time restore](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html), [Secrets Manager integration](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html), [Stopping an instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html)
- AWS Systems Manager: [Starting a session (port forwarding)](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html), [Fleet Manager Remote Desktop](https://docs.aws.amazon.com/systems-manager/latest/userguide/fleet-manager-remote-desktop-connections.html)
- Route 53: [Private hosted zone considerations](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-private-considerations.html), [IAM conditions for record sets](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/specifying-rrset-conditions.html)
- Networking and compute: [Lambda VPC access](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html), [Regional NAT gateway](https://aws.amazon.com/blogs/networking-and-content-delivery/introducing-amazon-vpc-regional-nat-gateway/), [Updating Amazon Linux without internet access](https://repost.aws/knowledge-center/ec2-al1-al2-update-yum-without-internet)
- [Let's Encrypt rate limits](https://letsencrypt.org/docs/rate-limits/)
- AWS Pricing API and Savings Plans offering rates, `us-west-2`, queried 2026-09-28.

## InvenTree API and Data Contract

Implement the InvenTree client in `backend/shared` so inventory sync and stock-posting jobs use one authenticated, timeout-bounded integration. Put only the required inventory job Lambdas in the VPC and allow them to reach the private InvenTree HTTPS endpoint. Keep checkout and payment handlers outside the VPC unless they require private connectivity. This avoids forcing unrelated public payment API calls through the NAT instance. If a checkout path must call InvenTree synchronously, document the reason and its egress needs, and prefer the durable job model below.

Give the integration service account only the InvenTree permissions required for reads and stock movements. Use API behavior verified against the pinned InvenTree release's docs/schema; do not guess endpoint names, payloads, or reservation semantics. Keep API tokens server-side. Bound retries and make non-idempotent requests safe.

Treat missing mappings, disabled parts, unexpected units, and insufficient stock as explicit errors, not zero stock or permission to substitute another part. An order may be `paid` while inventory posting is pending; fulfillment must remain blocked until the movement succeeds or an operator resolves the failure. Do not claim a distributed transaction across DynamoDB, providers, and InvenTree.

## Inventory Data Contract

Proposed on 2026-09-28. InvenTree facts below were verified against the 1.5.6 source (tag `1.5.6`, API version 530). Keys, attributes, and transaction pseudocode are in [DynamoDB data model](dynamodb-data-model.md#inventory-projection-and-reservations). The order, payment, and inventory state table is in [Payment processing](payment-processing.md#order-payment-and-inventory-states). Owner questions are listed [below](#inventory-owner-decisions); defaults marked *(default)* apply until the owner decides.

### Ownership

| Data | Authority | DynamoDB role |
|---|---|---|
| Physical quantity, locations, stock status, adjustments, BOM | InvenTree | Read-only projection (`observed_qty`) and display BOM |
| Price, description, sellability, category | DynamoDB catalog | Authoritative |
| SKU-to-part mapping (`fulfillment_mode`, `inventree_part_id`) | DynamoDB catalog, set only through `require_admin` handlers that validate the part in InvenTree | Authoritative |
| Checkout holds and committed-but-unobserved movements | DynamoDB | Reservation ledger and `reserved_qty` |
| Whether a physical movement happened | InvenTree stock tracking entries | Job records hold evidence (tracking IDs) only |

### Eligible stock

`observed_qty` for a part is the sum of `quantity - allocated` over stock items that meet every condition below. Use `GET /api/stock/` with explicit filters. Never use InvenTree's `in_stock` or `available` filters alone: in 1.5.6, `StockStatusGroups.AVAILABLE_CODES` includes `ATTENTION` (50), `DAMAGED` (55), and `RETURNED` (85), as well as `OK` (10) (`stock/status_codes.py`).

- `status=10` (OK) only *(default)*. Quarantined (75), damaged, returned, attention, lost, destroyed, and rejected stock is never sellable.
- `in_stock=true`: quantity above 0 and not assigned to a customer, a sales order, a parent item, a build, or consumption (`StockItem.IN_STOCK_FILTER`).
- Location in an explicit allowlist of InvenTree location IDs, queried with `cascade=false`. The allowlist is a per-environment Terraform variable passed to the inventory Lambdas. Its hash is `eligibility_version`. Never include the `Web orders – committed` or `Returns – inspection` locations. Exclude `external` locations.
- `expired=false`, when stock expiry is enabled.
- Subtract `allocated`, the build, sales, and transfer-order allocations made inside InvenTree, so stock the owner earmarks there isn't sold on the web.

The part must be `active`, not `virtual`, and not `trackable` *(default: serialized and trackable parts are rejected until serial selection is designed)*. `IPN` must equal the catalog SKU for STOCKED_PART mappings, as a cross-check *(default)*.

### Kits, BOMs and units

Every sellable SKU has exactly one `fulfillment_mode`:

- **`STOCKED_PART`:** reserve `inventree_part_id`. This is a single component, or a *finished kit* built in InvenTree through a Build Order. Building a kit consumes its components in InvenTree, so finished-kit stock and component stock never overlap.
- **`COMPONENTS`:** `inventree_part_id` is the kit's assembly part. Its BOM (`GET /api/bom/?part=<id>`, which includes inherited lines) becomes `stock_requirements`, and checkout reserves every component in one transaction. Finished stock of that assembly part is ignored. Sync warns if some exists, because it would be invisible to web sales.

A SKU never falls back from one mode to the other at checkout. A DynamoDB transaction can't express "finished kit OR components". A fallback would need two attempts and two sets of physical-movement rules, so it is rejected for now.

BOM validation happens in sync. The kit maps as `ERROR` (fail closed) unless all of these hold:

- `bom_validated` is true on the assembly part, and `bom_checksum` feeds `mapping_version`.
- Every line has `setup_quantity = 0`, `attrition = 0`, and no `rounding_multiple`. Those are build concepts with no per-sale meaning.
- No line is `optional` *(default)*.
- Every sub-part passes the part rules above.

`consumable` lines are excluded from reservation *(default)*, matching InvenTree, which doesn't allocate them in builds. Substitutes and `allow_variants` are never used: only the exact `sub_part` is reserved. Parts listed in `external_links` are bought by the customer and are never reserved.

Units: BOM `quantity` is stored in the sub-part's units, and InvenTree converts `raw_amount` on save. Stock quantities are in the part's units. The projection and `stock_requirements` keep InvenTree's decimal quantities, and checkout multiplies them by integer line quantities. If a part has no units or a count unit, its per-sale quantity must be an integer. A unit change on a part changes `mapping_version`, which invalidates carts priced against the old mapping.

Double counting is prevented structurally:

1. Projections are per part, so every SKU that uses a part shares one counter.
2. Each SKU has one mode.
3. InvenTree builds consume components.
4. Committed stock moves to an ineligible location.

### Sync and freshness

- **Prod schedule:** EventBridge Scheduler runs `inventory-sync` every **5 minutes**, with reserved concurrency 1. The `sync_version` condition also discards any out-of-order run. Dev runs the sync manually, before checkout tests.
- **Freshness limit:** checkout rejects a part whose `source_snapshot_at` is more than **20 minutes** old (four missed runs) with 503. Staleness is per part, so one failing part doesn't block unrelated SKUs.
- **Alarms:** warn when the last full success is more than 10 minutes old, or when any mapping is `ERROR`. Page when the last success is more than 20 minutes old, or when any `available_qty` is below 0.
- **Algorithm:** the pseudocode is in [DynamoDB data model](dynamodb-data-model.md#inventory-sync-pseudocode). Physical observations are applied as a delta. A sync never overwrites `reserved_qty`; it only retires `pending_retire` entries whose movements finished before the snapshot began, with `CLOCK_MARGIN_S` = 10 s.
- **Outages:** InvenTree upgrades (a few minutes) and short NAT or host outages stay inside the 20-minute window. After it, checkout fails closed for the affected parts.

### Physical movements

Three job kinds, each a DynamoDB job item and an SQS message (standard queue with DLQ):

| Job | When | InvenTree call | Projection effect |
|---|---|---|---|
| `COMMIT` | verified payment | `POST /api/stock/transfer/` from eligible locations to `Web orders – committed` | observed drops on the next sync, and the reservation retires in the same update |
| `UNCOMMIT` | refund or cancel after COMMIT and before shipping. If the refund arrived while COMMIT was `IN_PROGRESS` or `FAILED`, the COMMIT completion transaction creates it | transfer back from `committed` to the part's default eligible location | observed rises on the next sync |
| `SHIP` | admin marks the order shipped (only when the order is `paid`, COMMIT is `COMPLETED`, no dispute is open, and there is no `payment_exception`) | `POST /api/stock/remove/` from `committed` | none (the location is ineligible) |

Payment events never call InvenTree and never wait for a job. A COMMIT that is `IN_PROGRESS` or `FAILED` is never cancelled, because its movement may already have happened. A refund in that window is recorded on the order and carried into UNCOMMIT by the completion transaction ([Payment processing](payment-processing.md#order-payment-and-inventory-states), row 12).

Returns are recorded by staff in InvenTree into `Returns – inspection`, with status RETURNED (85, ineligible). Stock becomes sellable only when staff inspect it and move it to an eligible location with status OK. Nothing restocks automatically.

InvenTree 1.5.6 has no idempotency key on stock adjustments. Its adjustment endpoints also **do not reject** a quantity larger than the item holds: `take_stock` clamps to the item's quantity, and `move` transfers the whole item (`stock/models.py`; `StockAdjustmentItemSerializer` has no upper bound). Each transfer or remove request runs in one `transaction.atomic()`. The worker therefore:

1. **Claims the job.** Conditional update from `QUEUED`/`FAILED` to `IN_PROGRESS`, with `lease_owner` and a `lease_until` of 5 minutes.
2. **Probes for a previous attempt.** Search `GET /api/stock/track/?search=<job_key>`; tracking `notes` are searchable. If entries exist, verify their `deltas` against `plan`. On a match, go to step 5. On a mismatch, set `NEEDS_ATTENTION` and alert. Never repeat the movement.
3. **Plans from current stock.** Read eligible stock items and choose items FIFO by expiry, then creation. Require `quantity - allocated >= take` for every item chosen. A shortfall is a permanent `NEEDS_ATTENTION` failure, not a partial movement.
4. **Posts one request.** Send one `transfer` or `remove` for all parts, with `notes = "<job_key> order <orderId>"`. On a timeout or 5xx the outcome is unknown, so set `FAILED` with `next_attempt_at` at least **3 minutes** later. That is longer than the 90-second gunicorn timeout (`contrib/container/gunicorn.conf.py`), so the next attempt's probe sees any request that did commit. Retry at most 5 times, then `NEEDS_ATTENTION`.
5. **Completes.** Record the tracking IDs and run the completion transaction ([pseudocode](dynamodb-data-model.md#commit-job-completion-pseudocode)).

A sweeper runs every 5 minutes. It re-enqueues `INVJOB#OPEN` jobs whose lease or `next_attempt_at` has passed, and alerts on jobs open longer than 30 minutes.

**Assumption to verify in dev:** SHIP selects any stock of the part in the committed location, treating it as fungible. If the owner needs batch or serial traceability per order, SHIP must instead target the stock items created by the COMMIT split. The transfer response and tracking deltas must then be verified to return those item IDs.

### Admin stock changes

Admin stock changes go through authorized backend operations that write physical stock in InvenTree. Each admin handler must enforce the `Admins` Cognito group. Do not expose a generic InvenTree proxy or directly edit the DynamoDB projection from an admin form. Audit actor, part, location, quantity, reason, and resulting movement, then trigger a targeted sync of the affected parts. Catalog reads use DynamoDB, not synchronous InvenTree calls. Staff edits made directly in InvenTree through the jumpbox are equally valid, and the next sync picks them up.

## Reconciliation and Operations

Run reconciliation daily in prod, after every admin stock change, and after any InvenTree restore. It uses only index queries (no table scans):

| Check | Source | Action |
|---|---|---|
| `reserved_qty` equals the sum over `HELD` (`INVHOLD`), `COMMITTING` (open COMMIT jobs), and `pending_retire` entries | GSI2 `INVHOLD`, `INVJOB#OPEN`, `INVSTOCK` | Auto-repair with a conditional update on the old `reserved_qty` and `available_qty`, then alert |
| `available_qty = observed_qty - reserved_qty` | `INVSTOCK` | Auto-repair the same way, then alert |
| `available_qty < 0` | `INVSTOCK` | Alert with the orders holding the part (possible oversell) |
| `source_snapshot_at` older than the freshness limit | `INVSTOCK` | Alert |
| `HELD` past `expires_at` + 10 min | `INVHOLD` | Alert (the expiry sweeper is failing) |
| `pending_retire` entry older than 3 sync intervals | `INVSTOCK` | Alert (the movement is not observed: stock moved back, or the location is misconfigured) |
| Job `FAILED` or `NEEDS_ATTENTION`, or open longer than 30 min | `INVJOB#OPEN` | Alert; blocks fulfillment |
| InvenTree tracking notes matching `vp-<env>-` with no `COMPLETED` job, or a job `COMPLETED` whose tracking IDs are gone (for example after a PITR restore) | InvenTree `/api/stock/track/?search=vp-<env>-` | Alert; never auto-move stock |
| Committed-location quantity per part does not equal committed-but-not-shipped orders | InvenTree plus `ORDER#` queries | Alert |
| Mapping `ERROR`, or finished stock on a `COMPONENTS` kit | `INVMAP` | Alert |
| Payment event open longer than 30 min or in `NEEDS_ATTENTION`, or an order with `payment_exception` or an open dispute that holds stock | GSI2 `PAYEVT#OPEN`, `ORDER#` | Alert; blocks fulfillment; never auto-refund or auto-move stock |

Only projection arithmetic (the first two rows) is auto-repaired. Physical stock is never auto-adjusted.

- If reconciliation can't be trusted, disable checkout, keep all order and payment records, and reconcile before resuming.
- Record last-success timestamps and alert on aging projections and integration failures.
- Redact customer data, API tokens, and database credentials from logs.

### Inventory Owner Decisions

The defaults above let implementation proceed in dev. These need owner confirmation before prod:

1. Fulfillment mode per kit: finished kits (`STOCKED_PART`) or component-derived (`COMPONENTS`).
2. The eligible location IDs per environment, and whether any non-OK status (for example ATTENTION) is sellable. Default: OK only.
3. Two-step movement (commit at payment, remove at shipping) versus removal at payment. Also the names and IDs of the committed and returns locations.
4. Checkout hold duration. **Resolved 2026-09-28** ([Payment processing](payment-processing.md#inventory)):
   - a 31-minute Stripe session and a 35-minute reservation for both providers;
   - Stripe offers card and wallet methods only;
   - a PayPal `PENDING` capture holds stock for up to 72 hours.
5. Late payment after a hold was released: re-reserve, and if that fails, refund automatically, backorder, or leave it to the operator. Default: operator.
6. Refund or cancel after commit: whether UNCOMMIT is automatic. Also the policy for inspecting and restocking returns.
7. Policy for optional and consumable BOM lines. Defaults: optional lines are a mapping error; consumable lines are not reserved.
8. Whether trackable, serialized, batch-traced, or expiring parts are sold. Default: trackable parts are rejected.
9. Cart limits. Default: 10 lines and 75 distinct parts.
10. SKU-to-part identity rule. Default: IPN equals SKU.
11. Sync interval and freshness limit. Defaults: 5 and 20 minutes, with checkout blocked when stale.
12. Whether InvenTree build, sales, or transfer allocations are subtracted from sellable stock. Default: yes.
13. Partial refunds and chargebacks: whether they are money-only (default) or also affect stock. Default for disputes: an open dispute blocks shipping, and a lost dispute or a PayPal reversal is handled as a full refund.
14. Any existing `inventory_count` values: discard them (default), or import them once as an audited InvenTree stock count.
15. Whether the storefront shows exact counts or only in-stock/low/out, and the low-stock threshold.

Stage InvenTree upgrades in dev, pin the image/release, take and verify backups, run the supported database migration, and check API compatibility and worker processing before production promotion. Roll back the application only when schema compatibility is confirmed; otherwise use the tested database/media restore plan. Document health checks, credential rotation, alert response, and on-call recovery before production use.

## Implementation and Verification Checklist

1. The hosting design above is resolved: InvenTree 1.5.6 process topology, PostgreSQL-backed django-q2 broker, S3 media, RDS PostgreSQL 17 with verified TLS, secret delivery, approved CIDRs, jumpbox access, and Lambda connectivity to the private HTTPS endpoint. Complete the [open owner actions](#open-owner-actions) before prod go-live.
2. Build dev networking and service resources. Review security groups, route tables, public exposure, secret flow, and Terraform plans. Run format/validation; do not apply without operator authorization.
3. Deploy the dev application and run the [acceptance tests](#acceptance-tests): private DNS/TLS, jumpbox access through SSM, SSM management without SSH ingress, private RDS connectivity, media persistence, worker processing, email, alarms, and backup/restore.
4. Implement the [inventory data contract](#inventory-data-contract): mappings, sync, the reservation-aware projection, idempotent stock jobs, admin writes, and reconciliation. Update [Backend API](backend-api.md), [Payment processing](payment-processing.md), and [DynamoDB data model](dynamodb-data-model.md) when contracts change.
5. Test component and finished-kit stock without double counting, concurrent last-unit checkout, stale projection rejection, InvenTree downtime, failed/duplicate/out-of-order payment events, cancellation, retry after partial movement, and reconciliation after admin adjustment. Run the [inventory contract acceptance tests](payment-processing.md#inventory-acceptance-tests).
6. Validate the entire dev path from InvenTree stock to catalog availability, checkout reservation, verified payment, physical movement, reservation retirement, failure alerts, and restore. Promote only the reviewed equivalent to prod via [Infrastructure development workflow](infrastructure-development.md).

Never use production inventory or credentials to validate dev.
