# Backend API (API Gateway + Python Lambda)

This describes how the backend API is structured and deployed. Follow [Application architecture](application-architecture.md) for the general frontend/backend split, [DynamoDB data model](dynamodb-data-model.md) for data access, [Cognito authentication](cognito-authentication.md) for authorization, and [Infrastructure development workflow](infrastructure-development.md) for the dev-to-prod promotion rules that the deployment scripts below must follow.

## Folder layout

One flat subfolder per Lambda function under `/backend`, plus `shared/`:

```
backend/
  catalog/           HTTP: product/category reads (public)
  cart/              HTTP: cart read/update
  checkout/          HTTP: reserve stock, create Stripe/PayPal checkout, PayPal capture
  orders/            HTTP: order history, order detail
  admin/             HTTP: catalog/order CRUD and inventory job requests (Admins only)
  webhooks-stripe/   HTTP: Stripe webhook receiver (payment-event processor)
  webhooks-paypal/   HTTP: PayPal webhook receiver (payment-event processor)
  sweeper/           scheduled: hold expiry, payment-event re-drive, open-job re-enqueue
  inventory-sync/    scheduled/async (VPC): InvenTree stock/BOM sync and reconciliation
  inventory-jobs/    SQS (VPC): durable, idempotent InvenTree stock movements
  shared/            bundled into every zip; never deployed on its own
    auth.py, responses.py, validation.py, dynamodb.py, secrets.py, logging.py
    payments/        payment-event processor, decide(), provider clients (payment functions and sweeper only)
    inventory/       projection math, job items, SQS message schema
    inventree/       InvenTree client (inventory-sync and inventory-jobs only)
```

Each function folder holds a `handler.py`, a hash-locked `requirements.txt`, and `tests/`. Payment functions and `sweeper` pin `stripe==15.6.1` and one exact `requests` release (see [Payment processing](payment-processing.md#dependencies-and-provider-versions)). The inventory functions pin `requests`. Every function pins its own `boto3`. See [Packaging](#packaging) for how `shared/` is bundled.

## Functions and triggers

| Function | Trigger / event source | Routes owned | VPC | Timeout / concurrency |
|---|---|---|---|---|
| `catalog` | HTTP API | public catalog routes | no | 10 s |
| `cart` | HTTP API | `/cart` | no | 10 s |
| `checkout` | HTTP API | `/checkout/*` | no | 25 s |
| `orders` | HTTP API | `/orders`, `/orders/{orderId}` | no | 10 s |
| `admin` | HTTP API | the explicit `/admin/...` routes below | no | 15 s |
| `webhooks-stripe` | HTTP API | `/webhooks/stripe` | no | 20 s |
| `webhooks-paypal` | HTTP API | `/webhooks/paypal` | no | 20 s |
| `sweeper` | EventBridge Scheduler, every 5 minutes | none | no | 240 s, reserved concurrency 1 |
| `inventory-sync` | Scheduler `{"kind":"full_sync"}` every 5 minutes (prod only; dev runs it manually) and `{"kind":"reconcile"}` daily; async invoke `{"kind":"targeted_sync","part_ids":[…]}` from `admin` and `inventory-jobs` | none | yes | 300 s, reserved concurrency 1 |
| `inventory-jobs` | SQS event source mapping on the `inventory-jobs` queue | none | yes | 60 s |

- **`sweeper`:** runs three independent tasks, each with its own error handling and metric: expire `INVHOLD` reservations, re-drive `PAYEVT#OPEN` events, and re-enqueue and age-alert `INVJOB#OPEN` jobs. They share one function because their permissions already overlap.
- **`inventory-sync`:** reconciliation is one of its modes. Reserved concurrency 1 serializes full syncs, targeted syncs, and reconciliation. Throttled async invokes are retried by Lambda.
- **`inventory-jobs` queue:**
  - standard queue with a DLQ and `maxReceiveCount` 5;
  - visibility timeout 360 s (at least 6× the function timeout);
  - batch size 1 with `ReportBatchItemFailures`;
  - event-source maximum concurrency 2.
- **Job retries:** a job that fails in InvenTree is recorded as `FAILED` with `next_attempt_at`, and its message is deleted. `sweeper` re-enqueues it later. SQS redelivery covers only crashes.
- **No API Gateway integration:** `sweeper`, `inventory-sync`, and `inventory-jobs` have none.

## API Gateway

Use an HTTP API (not REST API) — cheaper and sufficient for this use case. Two Cognito JWT authorizers, one per user pool, as specified in [Cognito authentication](cognito-authentication.md#api-gateway-jwt-authorizers):

- `customer-jwt`: customer pool issuer, audience `[storefront_client_id]`.
- `admin-jwt`: admin pool issuer, audience `[admin_client_id]`.

Every protected route sets `authorizationScopes = ["aws.cognito.signin.user.admin"]` so API Gateway rejects ID tokens with 403 (invalid or expired tokens get 401; HTTP APIs cannot change these codes). Browsers send the Cognito **access token**. Public catalog browsing and the two webhook routes have no authorizer. Checkout and PayPal capture require `customer-jwt`. CORS preflight (`OPTIONS`) is answered by the API's CORS configuration without an authorizer.

| Method | Route | Lambda | Auth |
|---|---|---|---|
| GET | `/products` | `catalog` | none (public) |
| GET | `/products/{sku}` | `catalog` | none (public) |
| GET | `/categories/{tag}` | `catalog` | none (public) |
| GET | `/cart` | `cart` | `customer-jwt` |
| PUT | `/cart` | `cart` | `customer-jwt` |
| POST | `/checkout/stripe` | `checkout` | `customer-jwt` |
| POST | `/checkout/paypal` | `checkout` | `customer-jwt` |
| POST | `/checkout/paypal/capture` | `checkout` | `customer-jwt` + order ownership check in-handler. Captures and returns 202; never marks paid ([flow](payment-processing.md#paypal)) |
| GET | `/orders` | `orders` | `customer-jwt` |
| GET | `/orders/{orderId}` | `orders` | `customer-jwt` + order ownership check in-handler |
| GET, POST | `/admin/products` | `admin` | `admin-jwt` + `require_admin` (claim + live Cognito check) in-handler, as for every `/admin/...` route |
| GET, PUT | `/admin/products/{sku}` | `admin` | admin |
| PUT | `/admin/products/{sku}/mapping` | `admin` | admin. Sets `mapping_status = PENDING` and requests a targeted sync, which validates the mapping |
| GET | `/admin/orders` | `admin` | admin |
| GET | `/admin/orders/{orderId}` | `admin` | admin |
| POST | `/admin/orders/{orderId}/ship` | `admin` | admin. Writes a SHIP job and returns 202 |
| POST | `/admin/inventory/adjustments` | `admin` | admin. Writes an ADJUST job and returns 202 `{adjustmentId}` |
| GET | `/admin/inventory/adjustments/{adjustmentId}` | `admin` | admin |
| GET | `/admin/inventory/jobs` | `admin` | admin. Lists open jobs (`INVJOB#OPEN`) |
| POST | `/admin/inventory/sync` | `admin` | admin. Async-invokes `inventory-sync` and returns 202 |
| POST | `/webhooks/stripe` | `webhooks-stripe` | Stripe signature (no Cognito authorizer) |
| POST | `/webhooks/paypal` | `webhooks-paypal` | PayPal signature (no Cognito authorizer) |

Routes are explicit. There is no `ANY` or `{proxy+}` route. A new admin capability means a new row here, a closed request schema, and route-table tests (see [Async job contracts](#async-job-contracts)).

Webhook routes must skip the Cognito authorizer entirely (the caller is Stripe/PayPal, not a logged-in user) and instead verify the provider's own signature inside the handler, per [Payment processing](payment-processing.md).

## Private InvenTree Connectivity

Only `inventory-sync` and `inventory-jobs` attach to the environment VPC. Place their Lambda ENIs in the active private application subnets (`private_app_subnet_ids`, AZs a and b) with the `inventory_lambda_sg_id` security group. They call the environment's private InvenTree HTTPS endpoint by its private DNS name: `inventree.vitamin-packs.com` in prod or `inventree.dev.vitamin-packs.com` in dev. There is no load balancer.
- **Target:** the name resolves to the single InvenTree EC2 host, where Caddy terminates TLS with a publicly trusted certificate, so default certificate verification works.
- **Egress:**
  - The Lambda security group may egress on HTTPS to the InvenTree host security group.
  - It may also egress on TCP 443 through the NAT instance to reach Secrets Manager (the integration token) and the Lambda Invoke API (`inventory-jobs` requesting a targeted sync).
  - DynamoDB traffic uses its gateway endpoint. The endpoint policy must allow the table and `table/<name>/index/*`, because sync queries GSI2.
  - No SQS or CloudWatch Logs path is needed: the Lambda service polls and deletes SQS messages and ships logs.
- **No interface endpoints:** the owner confirmed on 2026-09-28 that Secrets Manager and Lambda interface endpoints are rejected for cost (about $7.30 per endpoint per AZ per month). The 5-minute secret cache and the 20-minute freshness limit absorb short NAT outages.
- **Ingress:** the InvenTree host security group accepts HTTPS only from this Lambda security group and the staff jumpbox.
- **Retries:** the host's private IP changes when it is replaced (60-second DNS TTL), so the shared InvenTree client retries connection errors with bounded backoff (see [InvenTree client](#inventree-client)).
- **Idle functions:** Lambda reclaims the network interfaces of a VPC function idle for 14 days and marks it `Inactive`. The next invoke fails while the function returns to `Pending`, which matters for the manually run dev sync. Retry after a few minutes.

Do not place RDS in Lambda subnets or allow Lambda security groups direct database access. EC2 alone connects to RDS on PostgreSQL's port, and the RDS security group accepts that port only from the EC2 application security group. Do not give the InvenTree EC2 instances public IPs or inbound SSH; use SSM. Keep checkout/payment functions outside the VPC unless a documented dependency requires InvenTree access, since VPC attachment changes their internet-egress requirements. The VPC/subnet and operator-access design is specified in [InvenTree integration](inventree-integration.md).

## InvenTree client

`backend/shared/inventree/` is imported only by `inventory-sync` and `inventory-jobs`. An import-boundary test enforces this, and so do IAM (no other role can read the token) and the network (no other function is in the VPC).

- **Configuration** (Lambda environment variables from Terraform outputs):
  - `INVENTREE_BASE_URL` (`https://` + `inventree_fqdn`) and `INVENTREE_TOKEN_SECRET_ARN`;
  - `ELIGIBLE_LOCATION_IDS`, `COMMITTED_LOCATION_ID`, `RETURNS_LOCATION_ID`;
  - `APP_ENV`.
  - At cold start the client fails fast if the hostname does not match `APP_ENV`.
- **Authentication:** `Authorization: Token <token>`, using the integration token from Secrets Manager. The token is cached for 5 minutes; on HTTP 401 the client re-reads it once and retries once, which supports the [overlap rotation](inventree-integration.md#secret-rotation). The integration user's InvenTree roles bound what the token can do, and InvenTree answers 403 outside them ([InvenTree API](https://docs.inventree.org/en/stable/api/)).
- **DNS and TLS:** the private hosted zone resolves through the VPC resolver. `requests` verifies the Let's Encrypt certificate with certifi. Each execution environment uses one `requests.Session`.
- **Timeouts:** connect 3 s; read 15 s for GETs and 30 s for stock POSTs. Every call is also capped by the Lambda's remaining time minus 2 s.
- **Retries:**
  - GETs retry connection errors, read timeouts, and 502/503/504 with exponential backoff and jitter, up to 3 attempts.
  - Stock POSTs retry only when the connection was never established. After a read timeout or a 5xx the outcome is unknown: the job becomes `FAILED` with `next_attempt_at` at least 3 minutes later, and the next attempt probes tracking entries first ([Physical movements](inventree-integration.md#physical-movements)).
  - A 400 or 403 is permanent: the job becomes `NEEDS_ATTENTION` and an alert fires. A 404 for a part or location is a mapping error.
- **Errors and redaction:**
  - The client raises typed errors (`InvenTreeUnavailable`, `InvenTreeAuthError`, `InvenTreeRejected`, `InvenTreeOutcomeUnknown`).
  - Each carries the method, path template, status, latency, and a sanitized reason: field names only, at most 200 characters.
  - Never log the token, the `Authorization` header, raw request or response bodies, or customer data. Job `last_error` uses the sanitized reason.
- **Operations:** the public surface is a closed set of named methods, for example `list_stock`, `get_bom`, `transfer`, `remove`, `adjust`, `search_tracking`. There is no generic `request(path)`. Verify request and response shapes against the pinned 1.5.6 schema (`/api-doc/`) in dev. Run the client contract tests against dev InvenTree before promoting any InvenTree upgrade.

## Async job contracts

Anything that touches InvenTree runs asynchronously. HTTP handlers write a DynamoDB job item (the durable outbox), send a pointer message to SQS, and return 202. `inventory-jobs` performs the movement. Keys and attributes are in [DynamoDB data model](dynamodb-data-model.md#inventory-job-orderorderid--invjobkind).

- **Job kinds:**
  - `COMMIT`, `UNCOMMIT`, `SHIP`: order-scoped, `ORDER#<orderId>` / `INVJOB#<kind>`.
  - `ADJUST`: an admin stock adjustment, `ADJ#<adjustmentId>` / `INVJOB#ADJUST`.
  - Every kind uses the same claim → probe → plan → single POST → complete algorithm.
- **ADJUST guard:** a decrease larger than the part's projected `available_qty` is rejected with 409 when it is enqueued, and checked again in the worker's plan, where a shortfall becomes `NEEDS_ATTENTION`. Admins cannot override this (owner decision, 2026-09-28).
  - When an ADJUST completes, the worker async-invokes a targeted sync of that part.
  - Which ADJUST operations the admin app offers is an open owner question. The default is add, remove, and count at one eligible location; transfers stay in the InvenTree UI.
- **SQS message:** the body is only `{"schema": 1, "pk": "...", "sk": "..."}`. The worker always re-reads the job item.
- **Unknown kinds:** an unknown kind or a newer `schema` moves the job to `NEEDS_ATTENTION`. It is never dropped or crash-looped.
- **Evolution:**
  - Add a kind readers-first: deploy `inventory-jobs` support before any producer emits it. Remove a kind only after its producers stop and no job of that kind is left under `INVJOB#OPEN`.
  - Item and message fields change expand-then-contract: add fields, keep readers tolerant, and remove fields only after every function reading them has been redeployed.
- **No generic proxy:**
  - Each InvenTree-affecting capability is a named route, a closed JSON request schema, and a job kind.
  - Never forward a path, method, query string, or body to InvenTree.
  - Accept part and location IDs only when they are in the DynamoDB mapping or the environment's location allowlist.
  - Return the backend's own response objects, never raw InvenTree JSON.
- **API changes:** API responses change additively. A breaking change gets a new route. Deploy the backend before the frontends.

## Handler conventions

```python
import json

from shared.auth import AuthServiceUnavailable


class NotFoundError(Exception):
    """Missing resource, or one the caller does not own (never reveal which)."""


def handler(event: dict, context) -> dict:
    try:
        body = do_work(event)
        return _response(200, body)
    except PermissionError as error:
        return _response(403, {"message": str(error)})
    except NotFoundError:
        return _response(404, {"message": "Not found"})
    except AuthServiceUnavailable:
        return _response(503, {"message": "Authorization service unavailable"})
    except ValueError as error:
        return _response(400, {"message": str(error)})


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
```

- Validate and parse input before touching DynamoDB or a payment provider.
- Return explicit status codes (`400` for bad input, `403` for authorization failures, `404` for missing resources) rather than letting unhandled exceptions produce an opaque `500`.
- Admin handlers call `require_admin(event)` (see [Cognito authentication](cognito-authentication.md#backend-authorization)) before doing anything else. It checks the token, the `Admins` claim, and live admin-pool membership. It fails closed: 403 when not authorized, 503 when Cognito is unreachable.
- Customer handlers get the caller's identity only from `require_customer_sub(event)` (the `sub` claim). Never read a user ID from the path, query string, or body. Carts, profiles, and order history are keyed by that `sub`.
- Order-scoped routes (`GET /orders/{orderId}`, `POST /checkout/paypal/capture`) load the order header and return 404 when it is missing or its `user_sub` is not the caller's `sub`.
- The `401` for missing/invalid/expired tokens comes from the API Gateway authorizer; Lambdas never see those requests.
- Never log tokens, the `Authorization` header, or full claim sets; log `sub`, route, and the authorization decision.

### Authorization tests

The backend, not the admin UI, is the security boundary. Prove it with tests that call the API directly:

- Unit: `parse_groups` for every claim representation and near-miss names; `require_admin` and `require_customer_sub` reject wrong `token_use`/`iss`/`client_id`. Also: `require_admin` returns 503 on Cognito errors and 403 on disabled or group-removed users (Cognito client stubbed).
- Route table: every route except the three public catalog routes and the two webhooks has an authorizer and the required scope. Every `/admin/...` route uses `admin-jwt`. Every route maps to exactly one function, and there is no `ANY` or `{proxy+}` route. `sweeper`, `inventory-sync`, and `inventory-jobs` have no API Gateway integration.
- Dev integration (raw HTTP): the [Cognito acceptance tests](cognito-authentication.md#acceptance-tests), including:
  - customer-token and ID-token rejection on every admin route;
  - immediate 403 after admin group removal;
  - cross-customer order/capture access returning 404.

## IAM

Each Lambda function has its own execution role, scoped to only what that function needs.

Every role:
- trusts `lambda.amazonaws.com` with an `aws:SourceAccount` condition;
- may call `logs:CreateLogStream` and `logs:PutLogEvents` on its own log group, which Terraform creates with a retention setting (no `logs:CreateLogGroup`);
- emits metrics as CloudWatch embedded-metric-format log lines, so it needs no `cloudwatch:PutMetricData`.

DynamoDB transactions have no IAM action of their own. `TransactWriteItems` is authorized by the underlying `PutItem`, `UpdateItem`, `DeleteItem`, and `GetItem` actions plus `dynamodb:ConditionCheckItem` ([DynamoDB transactions and IAM](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/transaction-apis-iam.html)). In the table below:
- **Tx** means those five actions on the table ARN.
- **read** means `GetItem`, `BatchGetItem`, and `Query`.

`dynamodb:LeadingKeys` cannot scope customer data, because a Lambda role is not a per-customer identity. Handlers enforce ownership in code.

| Function | DynamoDB | SQS (`inventory-jobs` queue only) | Secrets Manager `GetSecretValue` | Other |
|---|---|---|---|---|
| `catalog` | read on the table and `index/GSI1` | – | – | – |
| `cart` | read; `PutItem`, `UpdateItem`, `DeleteItem` | – | – | – |
| `checkout` | read + Tx ([reservation](dynamodb-data-model.md#checkout-reservation-pseudocode), provider reference, PayPal capture claim) | – (it never marks an order paid) | Stripe, PayPal | – |
| `orders` | read on the table and the index its queries use | – | – | – |
| `admin` | read + Tx; `Query` on `index/GSI2` | `SendMessage` | – | `cognito-idp:AdminGetUser` and `cognito-idp:AdminListGroupsForUser` on the **admin** pool ARN only (no Cognito writes); `lambda:InvokeFunction` on the `inventory-sync` ARN |
| `webhooks-stripe` | read + Tx (orders, refunds, reservations, projections, jobs, `PAYEVT#` ledger) | `SendMessage` | Stripe only | – |
| `webhooks-paypal` | as `webhooks-stripe` | `SendMessage` | PayPal only | – |
| `sweeper` | read + Tx; `Query` on `index/GSI2` (`INVHOLD`, `PAYEVT#OPEN`, `INVJOB#OPEN`) | `SendMessage` | Stripe, PayPal | – |
| `inventory-sync` | read + Tx; `Query` on `index/GSI2` | – | integration token only | VPC network-interface actions (below) |
| `inventory-jobs` | `GetItem`, `Query`, Tx | `ReceiveMessage`, `DeleteMessage`, `GetQueueAttributes`, `ChangeMessageVisibility` | integration token only | VPC network-interface actions; `lambda:InvokeFunction` on the `inventory-sync` ARN |

**VPC functions.** `inventory-sync` and `inventory-jobs` get the network-interface actions that Lambda needs to attach to the VPC, on `Resource: "*"` as Lambda requires ([Lambda VPC permissions](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html#configuration-vpc-permissions)):
- `ec2:CreateNetworkInterface`, `ec2:DescribeNetworkInterfaces`, `ec2:DescribeSubnets`, `ec2:DeleteNetworkInterface`;
- `ec2:AssignPrivateIpAddresses`, `ec2:UnassignPrivateIpAddresses`.

Each role also carries a Deny on those actions conditioned on `lambda:SourceFunctionArn`. That condition matches only calls made by the function's own code, so the code cannot use the actions while the Lambda service still can.

**Never granted:**
- `rds:*`, `rds-db:connect`, or any network path to PostgreSQL;
- the RDS master secret, the `inventree_app` secret, or the jumpbox secret;
- wildcard `dynamodb:*` or `secretsmanager:*`, or one broad policy shared across functions.

**Other principals:**
- **EventBridge Scheduler role:** trusts `scheduler.amazonaws.com` with `aws:SourceAccount`. It may call `lambda:InvokeFunction` on the `sweeper` and `inventory-sync` ARNs only.
- **API Gateway:** each route gets a Lambda permission whose `source_arn` is that route's execution ARN.
- **Deploying principal:** restrict it with `lambda:SubnetIds` and `lambda:SecurityGroupIds` so that only these two functions can be given the inventory subnets and security group.

## Packaging

**Model: bundled shared source, with no Lambda layer.** Each function is one self-contained zip containing:
- its locked dependencies;
- its `handler.py`;
- a copy of `backend/shared/`.

The source of `shared/` exists only once in the repository.

- **Runtime:** `python3.13` on `arm64` (Amazon Linux 2023; deprecation is scheduled for 2029-06-30, per [Lambda runtimes](https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html)). Move to `python3.14` after confirming that every pinned dependency supports it.
- **Dependencies:** each function's `requirements.txt` is locked with hashes. Install it with:

  ```sh
  pip install --require-hashes --only-binary=:all: \
    --platform manylinux2014_aarch64 --implementation cp \
    --python-version 3.13 --target <build>
  ```

  Every function pins `boto3` rather than relying on the runtime's copy, as [AWS recommends](https://docs.aws.amazon.com/lambda/latest/dg/python-package.html#python-package-searchpath). Provider SDKs appear only in the functions that use them; for example, no `stripe` in `catalog`.
- **Build:** `scripts/build-lambdas.sh` (planned) creates artifacts without changing any AWS resource.
  - It iterates over the explicit list of ten functions, never `backend/*/`.
  - It leaves out `__pycache__` and `tests/`.
  - It writes deterministic zips (sorted entries, fixed timestamps) that contain a `BUILD_INFO.json` with the git SHA and the sha256 of `shared/` and of the lock file.
  - It also writes a hash manifest, recorded by CI for each commit. The `publish` stage refuses to upload zips whose hashes differ from it.
- **Artifacts:** uploaded create-only to `s3://${project}-<env>-deploy-artifacts/lambda/<env>/<function>/<sha256>.zip`. That bucket is separate from the InvenTree artifacts bucket, which admits only the VPC endpoint. Terraform's `aws_lambda_function` resources take the S3 key and `source_code_hash` from the release manifest ([Deployment scripts](#deployment-scripts)). As a result:
  - only changed zips redeploy;
  - a `shared/` change redeploys every function, which is intended;
  - rollback redeploys a function's previous key.
- **Versioning:** `shared/` has no version number of its own. The git commit recorded in each zip is its version.
- **Rollout compatibility:** Terraform updates functions independently and in no guaranteed order, and in-flight records and messages cross versions. Shared data and message changes therefore follow expand-then-contract (see [Async job contracts](#async-job-contracts)). Consumers deploy before producers.
- **Local tests:**
  - Each function runs its tests in its own virtualenv, with only its lock file plus dev tools (`pytest`, `ruff`, `mypy`), so a missing dependency fails locally. `shared/` has its own tests.
  - An import-boundary test fails if anything other than `inventory-sync`/`inventory-jobs` imports `shared.inventree`, or anything other than the payment functions and `sweeper` imports `shared.payments`.
  - AWS clients are stubbed with `botocore.stub.Stubber`; transaction tests may use DynamoDB Local.
- **Acceptance:** building twice from one commit gives byte-identical zips, and each zip imports its handler in a clean `python3.13` arm64 container.

**Why no layer.** A layer version is immutable, and every function must pin its exact ARN ([Lambda layers](https://docs.aws.amazon.com/lambda/latest/dg/chapter-layers.html)). A layer would therefore add:
- a second artifact per change;
- code-and-layer version skew during rollout;
- one mixed dependency set, or one layer per dependency profile.

Its contents still count toward the 250 MB unzipped limit. Deployment-package modules also take precedence over layer modules, which invites version surprises. The zips here are small, so layers would not save anything meaningful.

## Deployment scripts

Backend releases use `scripts/deploy-dev.sh <stage>` and `scripts/deploy-prod.sh <stage>`.
- These are separate files with a hardcoded environment, so production can never be targeted by omission or typo.
- The stages, script contract, approval gates, and credentials are defined once, in [Infrastructure development workflow](infrastructure-development.md#release-workflow). This section covers only what is specific to Lambda.
- **No script runs a bare `terraform apply`.** `apply` accepts only a saved plan that the operator reviewed. In prod, the plan hash must also match a pushed release tag.

Lambda-specific contract:
- **Publish (dev):**
  1. `deploy-dev.sh publish` runs `scripts/build-lambdas.sh` over the explicit function list.
  2. It checks the zip hashes against CI's manifest for the commit.
  3. It uploads each zip with `If-None-Match` to `lambda/dev/<function>/<sha256>.zip`.
  4. It writes the release manifest `releases/dev/<commit>.json`.
- **Promote (prod):**
  - `deploy-prod.sh promote <sha>` copies the **identical** zips that passed dev to the prod bucket, re-uploading them after verifying each sha256. The bucket policy blocks `CopyObject`.
  - Prod never deploys a zip built separately from the one dev tested.
- **Release manifest:**
  - For each function: the S3 key, the hex sha256 (used in the key), and the base64 sha256 for `source_code_hash`, which Lambda reports as `CodeSha256` ([UpdateFunctionCode](https://docs.aws.amazon.com/lambda/latest/api/API_UpdateFunctionCode.html)).
  - It is the only `-var-file` for artifact inputs.
- **Ordering:**
  - Terraform updates functions in no guaranteed order.
  - A change that adds a job kind, message field, or item field ships its readers in one release and its first writer in a later one ([Async job contracts](#async-job-contracts)).
  - Deploy the backend before the frontends.
- **Rollback:** plan with the previous release manifest. Its zips are still in the bucket, and the new plan passes the same gates as any release.
- **Secrets:** the payment and InvenTree secret values never pass through these scripts or Terraform ([Secrets](infrastructure-development.md#secrets)).
