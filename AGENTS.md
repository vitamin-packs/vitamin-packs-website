# Agent Guidelines

For detailed guidelines on specific topics, refer to the modular documentation in the '/docs' directory. ALWAYS refer to the relevant .md file BEFORE generating any code.

The documentation is **proposed design**: the repository does not yet contain the applications, backend, Terraform, or scripts it describes, and no AWS resource is verified as deployed. Check decision status in the [Architecture decision register](docs/architecture-decisions.md) before relying on a contract. Do not resolve an open owner question yourself.

Never run deployment stages that change AWS (`publish`, `promote`, `apply`, `rollout-sites`, `rollback-sites`), `terraform apply`/`destroy`, state commands, or AWS mutation commands unless the user explicitly asks. See [Approval gates](docs/infrastructure-development.md#approval-gates).

- For Terraform work, follow [Terraform conventions](docs/terraform-conventions.md).
- For frontend, backend, hosting, or deployment-script work, follow [Application architecture](docs/application-architecture.md).
- For InvenTree installation and integration, follow [InvenTree integration](docs/inventree-integration.md).
- For storefront/admin HTML, JavaScript, static builds, and validation standards, follow [Frontend applications](docs/frontend-applications.md).
- For the dev-to-prod promotion workflow and deployment scripts, follow [Infrastructure development workflow](docs/infrastructure-development.md).
- For Cognito login/logout/account-management or API authorization, follow [Cognito authentication](docs/cognito-authentication.md).
- For Stripe/PayPal checkout and webhook handling, follow [Payment processing](docs/payment-processing.md).
- For the backend API, Lambda functions, and their deployment scripts, follow [Backend API](docs/backend-api.md).
- For DynamoDB keys, indexes, reservations, jobs, and timestamps, follow [DynamoDB data model](docs/dynamodb-data-model.md).
- For implementation sequencing and release gates, follow [Delivery plan](docs/development-and-deployment-plan.md).
- For decision status, open owner questions, and which document is authoritative for each topic, see [Architecture decision register](docs/architecture-decisions.md).
