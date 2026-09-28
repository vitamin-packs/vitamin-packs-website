# Infrastructure Development Workflow

## Environment Progression

All infrastructure development starts in `infra/dev`. Make, test, and review Terraform changes there before promoting the same intended configuration to `infra/prod`.

1. Implement infrastructure changes in `infra/dev` and reusable components in `infra/modules` when appropriate.
2. Run the required formatting and validation checks for the touched Terraform configuration.
3. Review the development plan and resolve any replacement, security, or remote-state concerns.
4. Promote the approved change to `infra/prod`, adjusting only environment-specific values.
5. Validate and review the production plan before applying it under the repository safety rules.

Do not introduce new infrastructure directly in `infra/prod`. Production changes must have an equivalent, validated development change unless an explicitly approved emergency process requires otherwise.

## Region

All Terraform resources must be created in `us-west-2` wherever the resource type allows it. The only accepted exception is ACM certificates used by CloudFront, which AWS requires to be issued in `us-east-1`; use the `aws.us_east_1` provider alias already defined in each root for that case only. Do not introduce additional regions or provider aliases without updating this rule.

## Deployment Scripts

Store deployment scripts in the root-level `scripts` directory. Keep scripts scoped to deployment automation and avoid placing reusable Terraform modules or environment root configurations there.

Scripts must:

- Require explicit target-environment selection instead of silently defaulting to production.
- Preserve Terraform state, credentials, and local `*.tfvars` files.
- Run only the Terraform commands appropriate to the requested operation.
- Avoid `terraform apply`, `terraform destroy`, AWS mutation commands, or state mutation unless the operator explicitly requests that action.

## Terraform Conventions

Follow the repository's [Terraform conventions](terraform-conventions.md) for module structure, validation, naming, tags, and safety requirements.