## Terraform Conventions

- Keep reusable modules split into `main.tf`, `variables.tf`, and `outputs.tf`. Add explicit variable types and descriptions, and add output descriptions.
- Preserve the `project`, `environment`, and `tags` module inputs. Environment values are restricted to `dev` or `prod` where exposed.
- Merge caller-provided tags with resource-specific `Name` and `Environment` tags. Resource names follow `${project}-${environment}-<purpose>`. The `project` value is `vitamin-packs` ([ADR-017](architecture-decisions.md#adr-017-terraform-project-value)), so names look like `vitamin-packs-dev-data`. S3 bucket names are global, so confirm they are available when reviewing the first plan.
- Create modules in `infra/modules`. Use one module for each AWS resource family. Orchestrator modules (for example `inventree`) compose family modules rather than owning a second implementation of their resources.
- Connect modules through outputs rather than duplicating resource IDs or other derived values.
- Keep provider constraints and `.terraform.lock.hcl` files consistent across root configurations. Every root sets `required_version = "~> 1.16.0"` and pins the provider major version. Commit lock files with hashes for every operator and CI platform (`terraform providers lock -platform=linux_amd64 …`).
- Every root except `bootstrap` uses the S3 backend with `use_lockfile = true` and its own key (`dev/`, `prod/`). See [State, plans and artifacts](infrastructure-development.md#state-plans-and-artifacts).
- Never hardcode AWS account IDs. Take them as per-environment inputs so prod can move to another account.
- Put non-secret, environment-specific configuration that needs review, such as InvenTree location IDs, in a committed `locals` file in the root (`infra/<env>/inventree-locations.tf`), never in `*.tfvars` ([ADR-026](architecture-decisions.md#adr-026-inventree-first-location-ids-by-second-apply)).
- Application data stores timestamps as fixed-format UTC ISO 8601 strings, except the DynamoDB `ttl` attribute ([ADR-018](architecture-decisions.md#adr-018-timestamp-format)). Keep Terraform-produced configuration, such as schedule expressions, consistent with that.

## Safety

- Never edit or commit Terraform state, `.terraform/` contents, saved plan files, secrets, credentials, or local `*.tfvars` files. Saved plans contain sensitive values in cleartext ([terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan)); treat them like state.
- Do not run `terraform apply`, `terraform destroy`, state mutation commands, or AWS mutation commands unless the user explicitly requests the operation. When authorized, apply only a saved, reviewed plan through the [release workflow](infrastructure-development.md#release-workflow) and its [approval gates](infrastructure-development.md#approval-gates). Never use `-auto-approve` or `-target`. Never run `destroy` from a script.
- Terraform creates secret containers only. Never add `aws_secretsmanager_secret_version`, or `random_password` for a secret value; values are set out of band ([Secrets](infrastructure-development.md#secrets)).
- Treat changes to CIDRs, remote-state settings, public ingress, resource identity, and resource names as potentially destructive. Explain replacement or exposure risk before changing them.
- Protect stateful resources with `lifecycle { prevent_destroy = true }`. This covers:
  - the state bucket;
  - the DynamoDB table (which also has deletion protection);
  - RDS (with deletion protection in prod, and `allow_major_version_upgrade = false` by default);
  - the media and deploy-artifact buckets;
  - both Cognito user pools;
  - the Secrets Manager secret containers.
- Give every Auto Scaling group whose capacity the scheduler or an operator manages `lifecycle { ignore_changes = [desired_capacity] }`. That is the jumpbox in both environments, and the InvenTree host and NAT instance in dev.
- Never add an `instance_refresh` block to the InvenTree Auto Scaling group: it starts a refresh on any launch-template change, ahead of migrations. See [InvenTree rollout](infrastructure-development.md#inventree-rollout).
- Adopt restored or existing resources with `import` blocks and renames with `moved` blocks in a reviewed plan, not with `terraform import` or `terraform state` commands.
- Preserve unrelated work in the tree. Do not populate placeholder application or script files unless the task specifically calls for it.

## Validation

- Format touched Terraform files with `terraform fmt <paths>` and check the full tree with `terraform fmt -check -recursive infra`.
- Validate every root after module or provider changes:

  ```sh
  for root in bootstrap dev prod; do
    terraform -chdir="infra/${root}" init -backend=false -input=false
    terraform -chdir="infra/${root}" validate
  done
  ```

  These checks need no AWS credentials and run in routine CI.
- Plans read remote state, so only an operator generates them, through the `plan` stage of `scripts/deploy-<env>.sh`. CI never plans. Review the risk-checker summary for replacement, exposure, IAM, capacity, and secret changes before any apply ([Deployment Scripts](infrastructure-development.md#deployment-scripts)).
