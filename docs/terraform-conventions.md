## Terraform Conventions

- Keep reusable modules split into `main.tf`, `variables.tf`, and `outputs.tf`. Add explicit variable types and descriptions, and add output descriptions.
- Preserve the `project`, `environment`, and `tags` module inputs. Environment values are restricted to `dev` or `prod` where exposed.
- Merge caller-provided tags with resource-specific `Name` and `Environment` tags. Resource names follow `${project}-${environment}-<purpose>`.
- Create modules in `infra/modules`. Use one module for each AWS resource family; these modules orchestrate family modules rather than owning a second implementation of their resources.
- Connect modules through outputs rather than duplicating resource IDs or other derived values.
- Keep provider constraints and `.terraform.lock.hcl` files consistent across root configurations.

## Safety

- Never edit or commit Terraform state, `.terraform/` contents, secrets, credentials, or local `*.tfvars` files.
- Do not run `terraform apply`, `terraform destroy`, state mutation commands, or AWS mutation commands unless the user explicitly requests the operation.
- Treat changes to CIDRs, remote-state settings, public ingress, resource identity, and resource names as potentially destructive. Explain replacement or exposure risk before changing them.
- Preserve unrelated work in the tree. Do not populate placeholder application or script files unless the task specifically calls for it.

## Validation

- Format touched Terraform files with `terraform fmt <paths>` and check the full tree with `terraform fmt -check -recursive infra`.
- Validate both roots after module or provider changes:

  ```sh
  terraform -chdir=infra/bootstrap validate
  terraform -chdir=infra/dev validate
  ```

- Run `terraform plan` only when initialized backend access and appropriate AWS credentials are available; review the plan for replacement and security changes before proposing an apply.
