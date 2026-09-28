# Application Architecture

## Frontend

There are two separate frontend applications, each its own S3 bucket and CloudFront distribution (see the `static-site` Terraform module): the customer-facing storefront in `frontend`, and the admin panel in `admin`. Build both with HTML, JavaScript, and Node.js tooling (React + Vite). The storefront is implemented as a responsive catalog/cart/account UI connected to the API, Cognito, and payment integration boundaries below. Deploy the generated static assets to Amazon S3 and deliver them through their CloudFront distribution.

Frontend work must:

- Keep source code, Node.js configuration, and build tooling within `frontend` (storefront) or `admin` (admin panel) — do not mix the two apps' source together.
- Configure CloudFront as the public delivery layer; do not expose the S3 origin for direct public use when CloudFront origin access is available.
- Use the API Gateway endpoint for browser-to-backend requests rather than invoking Lambda functions directly.
- Keep environment-specific API endpoints outside committed frontend source when they contain sensitive or deployment-specific values.
- Authenticate against Cognito directly from the browser (SRP auth flow) and embed login/logout/signup/account-management UI in the app itself; there is no Cognito Hosted UI domain to redirect to. The admin app authenticates against a separate admin user pool and app client (admin-create-only, TOTP MFA required); the storefront uses the customer pool. Browsers send Cognito access tokens to the API (see [Cognito authentication](cognito-authentication.md)).

Example browser request:

```javascript
const response = await fetch(`${apiBaseUrl}/hobbies`, {
  headers: { Accept: "application/json" },
});

if (!response.ok) {
  throw new Error("Unable to load hobbies.");
}

const hobbies = await response.json();
```

## Backend

Store Lambda function source and backend-specific dependencies in `backend`, one subfolder per domain (e.g. `catalog`, `cart`, `checkout`, `orders`, `admin`, `webhooks-stripe`, `webhooks-paypal`). All seven domains are implemented in Python. Expose their required HTTP operations through Amazon API Gateway (HTTP API, `api-lambda` Terraform module), with a Cognito JWT authorizer on every route except public catalog browsing and provider webhooks.

Keep shared code (DynamoDB access helpers, claim/authorization helpers, response helpers) in `backend/shared`. It ships as a Lambda layer rather than being copied into every function's deployment package, so there is exactly one copy of it at runtime as well as in source.

Backend work must:

- Validate and authorize API Gateway request data before processing it. Admin-only operations must call `backend/shared/auth.py`'s `require_admin` in the handler itself. It parses `cognito:groups` tolerantly with exact matching and confirms current `Admins` membership with a live admin-pool lookup (see [Cognito authentication](cognito-authentication.md#backend-authorization)). The JWT authorizer only proves the caller holds a valid admin-pool access token, not that they're an admin, and the frontend hiding admin routes is not access control. Customer handlers take identity only from the token's `sub` and enforce ownership of carts and orders.
- Read and write the shared DynamoDB single table (see [DynamoDB data model](dynamodb-data-model.md) and the `dynamodb` module) using its `PK`/`SK`/`GSI1`/`GSI2` key structure via `backend/shared/dynamodb.py`; do not introduce additional tables without updating that module.
- When writing a `PRODUCT#<sku>` item, only set `GSI1PK`/`GSI1SK` when the item is sellable individually (`sellable_individually = true`); omit them for kit-only components so they stay out of catalog browsing.
- Return explicit HTTP status codes and JSON responses that the frontend can handle predictably.
- Configure CORS in API Gateway only for the CloudFront-hosted frontend origins that require access (storefront and admin, per environment) — already wired in the `api-lambda` module from the `static-site` modules' URLs.
- Avoid hardcoding credentials, tokens, or environment-specific configuration in Lambda source; use Secrets Manager or SSM Parameter Store for Stripe/PayPal secrets.
- Keep shared Python code within `backend/shared` rather than duplicating it among Lambda functions.
- Give each Lambda function its own IAM role scoped to only the DynamoDB actions (and, once added, Secrets Manager access) it needs — don't attach one broad role to every function.
- Payment functions use the `payments` module's provider-specific Secrets Manager ARNs. Checkout routes require Cognito JWTs; Stripe and PayPal webhook routes are public API routes because they authenticate with provider signatures inside their handlers.
- Keep only backend functions that need private InvenTree connectivity attached to the environment VPC. Route inventory sync and stock-posting traffic to the private InvenTree HTTPS endpoint, which is resolved through private DNS and has no load balancer (see [InvenTree integration](inventree-integration.md)). Keep unrelated checkout and payment functions outside the VPC unless a documented requirement justifies the added dependency on the NAT instance. Browsers must never call the internal service.
- The `checkout` function calculates totals from DynamoDB products rather than trusting client prices, reserves inventory and writes order header/line-item records transactionally, then creates a Stripe Checkout Session or PayPal Order. PayPal approval is completed through the authenticated `/checkout/paypal/capture` route; final `paid` status comes only from a verified provider webhook, processed (or re-driven by the payment sweeper) by the payment-event processor, which re-fetches the provider object before acting (see [Payment processing](payment-processing.md#payment-event-ledger)).

Example Lambda response shape:

```python
import json


def handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"items": []}),
    }
```

## Deployment Boundaries

Store deployment automation in the root-level `scripts` directory. Infrastructure definitions remain in `infra`, with all infrastructure development first implemented and validated in `infra/dev` before promotion to `infra/prod`.

Deployment scripts must require an explicit target environment and must not default to production. Do not run destructive Terraform, AWS, or state operations unless the operator explicitly requests them.

Follow [Infrastructure development workflow](infrastructure-development.md) for environment promotion and [Terraform conventions](terraform-conventions.md) for Terraform structure, safety, and validation.