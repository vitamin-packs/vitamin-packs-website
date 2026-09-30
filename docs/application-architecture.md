# Application Architecture

This is **proposed design**. The repository contains no application, backend, Terraform, or script source yet, so the modules and paths below are planned, not existing. Decisions and their status are recorded in the [Architecture decision register](architecture-decisions.md).

## Frontend

There are two separate frontend applications, each with its own S3 bucket and CloudFront distribution (from the planned `static-site` Terraform module): the customer-facing storefront in `frontend`, and the admin panel in `admin`. Build both with HTML, JavaScript, and Node.js tooling (React + Vite). The storefront is a responsive catalog/cart/account UI connected to the API, Cognito, and payment integration boundaries below. Deploy the generated static assets to Amazon S3 and deliver them through their CloudFront distribution.

Frontend work must:

- Keep source code, Node.js configuration, and build tooling within `frontend` (storefront) or `admin` (admin panel) — do not mix the two apps' source together.
- Configure CloudFront as the public delivery layer; do not expose the S3 origin for direct public use when CloudFront origin access is available.
- Use the API Gateway endpoint for browser-to-backend requests rather than invoking Lambda functions directly.
- Keep environment-specific API endpoints outside committed frontend source when they contain sensitive or deployment-specific values.
- Authenticate against Cognito directly from the browser (SRP auth flow) and embed login/logout/signup/account-management UI in the app itself; there is no Cognito Hosted UI domain to redirect to. The admin app authenticates against a separate admin user pool and app client (admin-create-only, TOTP MFA required); the storefront uses the customer pool. Browsers send Cognito access tokens to the API (see [Cognito authentication](cognito-authentication.md)).

Example browser request:

```javascript
const response = await fetch(`${apiBaseUrl}/products`, {
  headers: { Accept: "application/json" },
});

if (!response.ok) {
  throw new Error("Unable to load products.");
}

const products = await response.json();
```

## Backend

Store Lambda function source and backend-specific dependencies in `backend`, one flat subfolder per Lambda function. There are eleven functions, all in Python, each with its own execution role (see [Backend API](backend-api.md#functions-and-triggers)):

- eight HTTP functions behind Amazon API Gateway (HTTP API, `api-lambda` Terraform module): `catalog`, `cart`, `checkout`, `orders`, `account`, `admin`, `webhooks-stripe`, `webhooks-paypal`. Every route has a Cognito JWT authorizer except public catalog browsing and provider webhooks.
- `sweeper`, run by EventBridge Scheduler. It expires holds, re-drives payment events, and re-enqueues open inventory jobs.
- `inventory-sync` (scheduled or async-invoked) and `inventory-jobs` (SQS-driven). These are the only functions that call InvenTree.

Keep shared code (DynamoDB, claim/authorization, response, payment-processor, and InvenTree-client helpers) in `backend/shared`. At build time it is copied into each function's zip alongside that function's own locked dependencies; there is no Lambda layer. Every zip is then self-contained and rolls back on its own, and no function gets another function's dependencies. The source still exists only once, in `backend/shared` (see [Backend API](backend-api.md#packaging)).

Backend work must:

- Validate and authorize API Gateway request data before processing it. Admin-only operations must call `backend/shared/auth.py`'s `require_admin` in the handler itself. It parses `cognito:groups` tolerantly with exact matching and confirms current `Admins` membership with a live admin-pool lookup (see [Cognito authentication](cognito-authentication.md#backend-authorization)). The JWT authorizer only proves the caller holds a valid admin-pool access token, not that they're an admin, and the frontend hiding admin routes is not access control. Customer handlers take identity only from the token's `sub` and enforce ownership of carts, profiles, and orders.
- Read and write the shared DynamoDB single table (see [DynamoDB data model](dynamodb-data-model.md) and the planned `dynamodb` module) using its `PK`/`SK`/`GSI1`/`GSI2` key structure via `backend/shared/dynamodb.py`; do not introduce additional tables without updating that module.
- When writing a `PRODUCT#<sku>` item, only set `GSI1PK`/`GSI1SK` when the item is sellable individually (`sellable_individually = true`); omit them for kit-only components so they stay out of catalog browsing.
- Return explicit HTTP status codes and JSON responses that the frontend can handle predictably.
- Configure CORS in API Gateway only for the CloudFront-hosted frontend origins that require access (storefront and admin, per environment). The planned `api-lambda` module takes these origins from the `static-site` modules' outputs.
- Avoid hardcoding credentials, tokens, or environment-specific configuration in Lambda source; Stripe and PayPal credentials live only in Secrets Manager ([Payment processing](payment-processing.md#secrets)).
- Keep shared Python code within `backend/shared` rather than duplicating it among Lambda functions.
- Give each Lambda function its own IAM role scoped to only the DynamoDB, SQS, and Secrets Manager actions it needs, per the [IAM matrix](backend-api.md#iam) — don't attach one broad role to every function.
- Payment functions use the provider-specific Secrets Manager ARNs from the planned `payments` module. Checkout routes require Cognito JWTs; Stripe and PayPal webhook routes are public API routes because they authenticate with provider signatures inside their handlers.
- Attach only `inventory-sync` and `inventory-jobs` to the environment VPC. They call the private InvenTree HTTPS endpoint, which is resolved through private DNS and has no load balancer (see [InvenTree integration](inventree-integration.md)). All other functions stay outside the VPC, including checkout, the webhooks, `sweeper`, and `admin`, so provider and Cognito calls never depend on the NAT instance. `admin` never calls InvenTree: stock adjustments, shipping, and sync requests become typed asynchronous jobs (see [Backend API](backend-api.md#async-job-contracts)). Browsers must never call the internal service.
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