# vitamin-packs website

An online store for **vitamin packs**: kits of assembly hardware (screws, nuts, washers and similar) bundled for a project. They are not dietary supplements. Stock is fungible and does not expire.

> **Status: design only.** The repository currently holds documentation, not code. There is no `infra/`, `backend/`, `frontend/`, `admin/`, or `scripts/` yet, and no AWS resource has been verified as deployed. Every path, module, and route in the docs is proposed until implemented. Decision status is tracked in the [Architecture decision register](docs/architecture-decisions.md); do not resolve its open owner questions yourself.

## What it is

- **Storefront** (`frontend/`): a responsive React + Vite static app for browsing the catalog, cart, checkout, and order history. Browsing needs no login.
- **Admin panel** (`admin/`): a separately built and deployed React + Vite app for staff. Privileged operations are authorized in the backend, not just hidden in the UI.
- **Delivery:** each app has its own private S3 bucket behind its own CloudFront distribution.
- **API:** API Gateway (HTTP API) in front of eleven Python Lambda functions in `backend/`, with shared code in `backend/shared`.
- **Data:** one DynamoDB table for catalog, customer, and order state, plus a synced sellable-stock projection and reservations.
- **Identity:** two Cognito user pools with embedded SRP login (no Hosted UI): a customer pool, and an admin-create-only pool with required TOTP MFA.
- **Payments:** Stripe and PayPal. The backend computes prices; only a verified provider webhook can mark an order paid.
- **Inventory:** InvenTree 1.5.6 is the authority for physical stock and kit BOMs. It runs privately on EC2 with RDS PostgreSQL in a per-environment VPC. Browsers never call it; only two inventory Lambdas do. Staff reach its UI through a Windows jumpbox over an SSM tunnel.
- **Infrastructure:** Terraform in `us-west-2`, built and validated in `infra/dev` before promotion to `infra/prod`.

## Constraints

- Prod InvenTree hosting stays under $50/month; dev runs on demand and is stopped nightly.
- One staff user. Recovery objectives are measured in hours, so the design is single-node and single-AZ.
- Dev and prod share one AWS account for now, so nothing may hardcode an account ID.

## Planned repository layout

```text
infra/       bootstrap/ dev/ prod/ modules/
backend/     one folder per Lambda, plus shared/
frontend/    storefront
admin/       admin panel
scripts/     deployment automation
docs/        design documents (exists)
runbooks/    operator procedures (exists)
```

## Deployment safety

- CI never holds AWS credentials. It runs checks only and never plans, publishes, or applies.
- Every apply is run locally by the owner through IAM Identity Center with MFA, applying only a saved, hash-matched plan.
- Prod is approved by a pushed annotated tag `prod/<date>-<n>` carrying the plan hash.
- Do not run `publish`, `promote`, `apply`, `rollout-sites`, `rollback-sites`, or any AWS-changing command without explicit approval. See [Approval gates](docs/infrastructure-development.md#approval-gates).

## Documentation

Start with the [Architecture decision register](docs/architecture-decisions.md) and the [Delivery plan](docs/development-and-deployment-plan.md).

| Topic | Document |
|---|---|
| Decisions, open questions, which doc is authoritative | [Architecture decisions](docs/architecture-decisions.md) |
| Implementation order and release gates | [Delivery plan](docs/development-and-deployment-plan.md) |
| Frontend/backend split and boundaries | [Application architecture](docs/application-architecture.md) |
| Storefront and admin apps | [Frontend applications](docs/frontend-applications.md) |
| Lambdas, routes, IAM, async jobs | [Backend API](docs/backend-api.md) |
| DynamoDB keys, indexes, reservations | [DynamoDB data model](docs/dynamodb-data-model.md) |
| Login and API authorization | [Cognito authentication](docs/cognito-authentication.md) |
| Stripe/PayPal checkout and webhooks | [Payment processing](docs/payment-processing.md) |
| InvenTree hosting, VPC, inventory contract | [InvenTree integration](docs/inventree-integration.md) |
| Release workflow, credentials, secrets | [Infrastructure development workflow](docs/infrastructure-development.md) |
| Terraform structure and safety | [Terraform conventions](docs/terraform-conventions.md) |

## Runbooks

Operator procedures live in [runbooks/](runbooks/):

- [Staff access to InvenTree (Windows jumpbox)](runbooks/inventree_staff_access.md)

## Local setup

Not documented yet. Prerequisites, local setup, and the non-production testing process will be added once a runnable vertical slice exists ([Delivery plan, Phase 1](docs/development-and-deployment-plan.md#phase-1-repository-and-delivery-foundations)).

## License

See [LICENSE](LICENSE).
