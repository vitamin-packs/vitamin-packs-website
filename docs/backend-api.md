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
  shared/            common code (DynamoDB access helpers, claim helpers, response helpers) imported by the folders above
```

Each domain folder is its own Lambda deployment package: its own `requirements.txt` plus a handler module. Keep shared logic in `backend/shared` and package it alongside each function at build time rather than duplicating it.

## API Gateway

Use an HTTP API (not REST API) — cheaper and sufficient for this use case. One Cognito JWT authorizer, configured against the User Pool's `user_pool_id`/issuer (see [Cognito authentication](cognito-authentication.md)), attached to every route except public catalog browsing and the two webhook routes (which authenticate differently — see below). Checkout and PayPal capture require the Cognito JWT.

| Method | Route | Lambda | Auth |
|---|---|---|---|
| GET | `/products` | `catalog` | none (public) |
| GET | `/products/{sku}` | `catalog` | none (public) |
| GET | `/categories/{tag}` | `catalog` | none (public) |
| GET | `/cart` | `cart` | Cognito JWT |
| PUT | `/cart` | `cart` | Cognito JWT |
| POST | `/checkout/stripe` | `checkout` | Cognito JWT |
| POST | `/checkout/paypal` | `checkout` | Cognito JWT |
| POST | `/checkout/paypal/capture` | `checkout` | Cognito JWT |
| GET | `/orders` | `orders` | Cognito JWT |
| GET | `/orders/{orderId}` | `orders` | Cognito JWT |
| * | `/admin/*` | `admin` | Cognito JWT + `Admins` group check in-handler |
| POST | `/webhooks/stripe` | `webhooks-stripe` | Stripe signature (no Cognito authorizer) |
| POST | `/webhooks/paypal` | `webhooks-paypal` | PayPal signature (no Cognito authorizer) |

Webhook routes must skip the Cognito authorizer entirely (the caller is Stripe/PayPal, not a logged-in user) and instead verify the provider's own signature inside the handler, per [Payment processing](payment-processing.md).

## Handler conventions

```python
import json


def handler(event: dict, context) -> dict:
    try:
        body = do_work(event)
        return _response(200, body)
    except PermissionError as error:
        return _response(403, {"message": str(error)})
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
- Admin handlers call `require_admin(event)` (see [Cognito authentication](cognito-authentication.md)) before doing anything else.

## IAM

One execution role per Lambda function, scoped to only what that function needs:

- `catalog`, `cart`, `orders`: read (and, for `cart`, write) on the DynamoDB table.
- `checkout`: DynamoDB write (reserve inventory, create order) + read access to the Stripe/PayPal secrets.
- `admin`: full DynamoDB read/write on the table.
- `webhooks-stripe`/`webhooks-paypal`: DynamoDB write (mark order paid, write the idempotency marker) + read access to that provider's secret only.

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
