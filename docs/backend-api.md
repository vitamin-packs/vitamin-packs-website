# Backend API (API Gateway + Python Lambda)

This describes how the backend API is structured and deployed. Follow [Application architecture](application-architecture.md) for the general frontend/backend split, [DynamoDB data model](dynamodb-data-model.md) for data access, [Cognito authentication](cognito-authentication.md) for authorization, and [Infrastructure development workflow](infrastructure-development.md) for the dev-to-prod promotion rules that the deployment scripts below must follow.

## Folder layout

One subfolder per domain under `/backend`, matching the routes table below:

```
backend/
  catalog/          GET product/category endpoints
  cart/              cart read/update endpoints
  checkout/          create Stripe/PayPal checkout sessions
  orders/            order history, order detail
  admin/             product/inventory/order CRUD (Admins group only)
  webhooks-stripe/    Stripe webhook receiver
  webhooks-paypal/    PayPal webhook receiver
    inventory-sync/     scheduled InvenTree stock/BOM synchronization
    inventory-jobs/     durable, idempotent InvenTree stock movements
  shared/            common code (DynamoDB access helpers, claim helpers, response helpers) imported by the folders above
```

Each domain folder is its own Lambda deployment package: its own `requirements.txt` plus a handler module. Keep shared logic in `backend/shared` and package it alongside each function at build time rather than duplicating it.

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
| POST | `/checkout/paypal/capture` | `checkout` | `customer-jwt` + order ownership check in-handler |
| GET | `/orders` | `orders` | `customer-jwt` |
| GET | `/orders/{orderId}` | `orders` | `customer-jwt` + order ownership check in-handler |
| * | `/admin/*` | `admin` | `admin-jwt` + `require_admin` (claim + live Cognito check) in-handler |
| POST | `/webhooks/stripe` | `webhooks-stripe` | Stripe signature (no Cognito authorizer) |
| POST | `/webhooks/paypal` | `webhooks-paypal` | PayPal signature (no Cognito authorizer) |

Webhook routes must skip the Cognito authorizer entirely (the caller is Stripe/PayPal, not a logged-in user) and instead verify the provider's own signature inside the handler, per [Payment processing](payment-processing.md).

## Private InvenTree Connectivity

Only the inventory synchronization and stock-movement workers that call InvenTree should attach to the environment VPC. Place their Lambda ENIs in the active private application subnets and call the environment's private InvenTree HTTPS endpoint by its private DNS name: `inventree.vitamin-packs.com` in prod or `inventree.dev.vitamin-packs.com` in dev. There is no load balancer.
- **Target:** the name resolves to the single InvenTree EC2 host, where Caddy terminates TLS with a publicly trusted certificate, so default certificate verification works.
- **Egress:** the Lambda security group may egress on HTTPS to the InvenTree host security group, and on TCP 443 through the NAT instance to reach Secrets Manager and SQS. DynamoDB traffic uses its gateway endpoint.
- **Ingress:** the InvenTree host security group accepts HTTPS only from this Lambda security group and the staff jumpbox.
- **Retries:** the host's private IP changes when it is replaced (60-second DNS TTL), so the shared InvenTree client must retry connection errors with bounded backoff.

Do not place RDS in Lambda subnets or allow Lambda security groups direct database access. EC2 alone connects to RDS on PostgreSQL's port, and the RDS security group accepts that port only from the EC2 application security group. Do not give the InvenTree EC2 instances public IPs or inbound SSH; use SSM. Keep checkout/payment functions outside the VPC unless a documented dependency requires InvenTree access, since VPC attachment changes their internet-egress requirements. The VPC/subnet and operator-access design is specified in [InvenTree integration](inventree-integration.md).

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
- Route table: every route except the three public catalog routes and the two webhooks has an authorizer and the required scope. Every `/admin/*` route uses `admin-jwt`.
- Dev integration (raw HTTP): the [Cognito acceptance tests](cognito-authentication.md#acceptance-tests), including:
  - customer-token and ID-token rejection on every admin route;
  - immediate 403 after admin group removal;
  - cross-customer order/capture access returning 404.

## IAM

One execution role per Lambda function, scoped to only what that function needs:

- `catalog`, `cart`, `orders`: read (and, for `cart`, write) on the DynamoDB table.
- `checkout`: DynamoDB `TransactWriteItems` (reserve stock projections, create the order and reservation, guard the cart) + read access to the Stripe/PayPal secrets. See [DynamoDB data model](dynamodb-data-model.md#checkout-reservation-pseudocode).
- `admin`: full DynamoDB read/write on the table, plus `cognito-idp:AdminGetUser` and `cognito-idp:AdminListGroupsForUser` on the **admin** user pool ARN only (for the live check in `require_admin`). No Cognito write actions.
- `webhooks-stripe`/`webhooks-paypal`: DynamoDB write (mark order paid, move the reservation to `COMMITTING`, create the COMMIT job, write the idempotency marker), `sqs:SendMessage` on the inventory-jobs queue, and read access to that provider's secret only.
- Reservation-expiry sweeper: DynamoDB read/write on reservations, orders, and projections, plus provider secrets to expire sessions. It calls provider APIs, so it runs outside the VPC. Its function placement is decided with the backend domain layout (resolution Prompt 3).
- `inventory-sync`/`inventory-jobs`: only the DynamoDB/SQS/secrets permissions required by their sync or movement workflow, plus VPC network access to the private InvenTree HTTPS endpoint (`AWSLambdaVPCAccessExecutionRole` permissions). Do not grant these functions RDS credentials or direct database access.

Do not attach a single broad "DynamoDB full access" or "Secrets Manager full access" policy shared across every function.

## Packaging

Each function's deployment package is built from its own folder: install `requirements.txt` into a build directory, add the handler and `shared/`, then zip. Terraform's `aws_lambda_function` resources (added when the API/Lambda module is created) reference the resulting zip artifacts, uploaded to an S3 bucket rather than inlined, so packages aren't limited by Terraform's inline size limits.

## Deployment scripts

Create `scripts/deploy-dev.sh` and `scripts/deploy-prod.sh` — separate scripts per environment (not one script with an environment flag) so there's no risk of a default or typo silently targeting production. Each script must, per [Infrastructure development workflow](infrastructure-development.md):

- Build and zip every `/backend/*` function into the environment's artifact location.
- Run `terraform -chdir=infra/<env> apply` only after the operator has explicitly invoked that script for that environment — the script itself must not be invoked automatically as part of some other workflow that could reach prod unintentionally.
- Preserve Terraform state, credentials, and local `*.tfvars` files — never print or persist them.
- Fail fast (`set -euo pipefail`) rather than continuing after a packaging or `terraform` error.

Skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="dev"                 # hardcoded per script — see deploy-prod.sh for the prod copy
INFRA_DIR="infra/${ENVIRONMENT}"
BUILD_DIR="$(mktemp -d)"

for fn_dir in backend/*/; do
  fn_name="$(basename "${fn_dir}")"
  [ "${fn_name}" = "shared" ] && continue

  pkg_dir="${BUILD_DIR}/${fn_name}"
  mkdir -p "${pkg_dir}"
  pip install -r "${fn_dir}requirements.txt" -t "${pkg_dir}" --quiet
  cp -r "${fn_dir}"*.py backend/shared "${pkg_dir}/"
  (cd "${pkg_dir}" && zip -qr "../${fn_name}.zip" .)
done

# Upload zips to the artifact bucket, then apply.
aws s3 sync "${BUILD_DIR}" "s3://${ARTIFACT_BUCKET}/lambda/" --exclude "*" --include "*.zip"
terraform -chdir="${INFRA_DIR}" apply
```

`deploy-prod.sh` is the same shape with `ENVIRONMENT="prod"` — keep them as two files, not a shared script parameterized by an argument, so production can never be targeted by omission.
