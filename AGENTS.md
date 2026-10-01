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
- For operator procedures, such as staff access to InvenTree, see the runbooks in the '/runbooks' directory.
- For decision status, open owner questions, and which document is authoritative for each topic, see [Architecture decision register](docs/architecture-decisions.md).

<!-- BEGIN AWS Agent Toolkit rules -->
# AWS Guidance for the new AWS experience

This user has signed up for the new AWS experience. This experience lets you sign into AWS using a social provider and requires the following additional context.

Where this guidance conflicts with the project's own instructions, the project's instructions take precedence.

## Context

### Terminology

- Say "project" instead of "account"; a project contains an AWS account and settings for sharing with other collaborators.
- Say "team member" instead of "IAM user"; users are invited by email, not created or federated in IAM.
- Say "AWS Settings" for management tasks at [settings.aws.com](https://settings.aws.com/) (project management, billing, team members, and spend limits). Users view actual AWS resources in the AWS Management Console.
- Say "selected Region" instead of "home Region".
- The user has a managed IAM experience, including managed service control policies (SCPs) and resource control policies (RCPs). IAM policies are still needed to let services work with each other. For questions about SCPs or RCPs, refer to https://docs.aws.amazon.com/accounts/latest/reference/scps-and-rcps-for-projects.html.

### Constraints

- All projects share a single Region determined by the user's contact address. Resources cannot be created in other Regions.
- Create all Regional resources in the project's assigned Region. Do not create Lambda, API Gateway, or other Regional resources in any other Region.
- Direct users to confirm their Region in AWS Settings > View all projects > Overview > Additional Info > Region. If they cannot confirm it, check `~/.aws/config`.
- AWS WAF and CloudWatch Logs resources may be created in `us-east-1` only when a global resource (such as global WAF) requires a connection to dependencies there. Do not use `us-east-1` for other purposes. When inventorying resources, include `us-east-1` for CloudWatch Logs or WAF when relevant.
- Do not use Lambda@Edge, CloudFormation StackSets, cross-Region replication for DynamoDB/S3/RDS, multi-Region KMS keys, or Route 53 cross-Region routing (geolocation, latency-based, or failover).
- CloudFront is global and its actions are allowed in `us-east-1`; its Lambda function URL or API Gateway origin must still be created in the project's selected Region.
- In `eu-north-1`, Amazon Rekognition, Amazon Textract, Amazon Personalize, and AWS App Runner are not available.
- Human IAM permissions are managed by AWS. Do not assign roles to team members unless absolutely necessary.
- A paid plan may have a spend limit that pauses the project. If resources suddenly become inaccessible after previously working, ask about the spend limit, direct the user to AWS Settings > Billing, and check whether the user upgraded to the paid plan. Only project owners can modify a spend limit.
- Ask whether the user wants successfully created resources cleaned up or kept to reduce cost.
- The user manages billing, spend limits, and invoices in AWS Settings. Budgets and cost optimization are managed in the AWS Billing and Cost Management console.
- If a service is unavailable, run `aws freetier get-account-plan-state`. For `FREE`, check https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html#supported-services-free-tier. For `PAID`, check https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html#supported-services-paid-plan. If neither list includes the service, check https://docs.aws.amazon.com/accounts/latest/reference/supported-services-sign-up-new.html#unsupported-services; advanced features may need activation.
- Users can activate advanced AWS services and capabilities.
- Before an AWS task, check whether a relevant AWS skill is available and load it with `retrieve_skill`; prefer that guidance over general knowledge.

### Help level

- Selected help level: HIGH (user-selected 2026-10-01). Do not ask again unless the user requests a change.
- Explain what each step does and why before executing it.
- Suggest alternatives when a better approach exists.
- Flag best practices and explain trade-offs.
- Execute the user's choice if they disagree with a suggestion.

<!-- END AWS Agent Toolkit rules -->
