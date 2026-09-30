# Infrastructure Development Workflow

This document is the single authority for how changes reach dev and prod. The workflow and scripts below are **proposed design**. As of 2026-09-28 the repository contains no `infra/`, `scripts/`, or CI workflow, so nothing here is implemented or deployed.

## Environment Progression

All infrastructure development starts in `infra/dev`. Make, test, and review Terraform changes there before promoting the same intended configuration to `infra/prod`.

1. Implement infrastructure changes in `infra/dev` and reusable components in `infra/modules` when appropriate.
2. Run the required formatting and validation checks for the touched Terraform configuration.
3. Review the development plan and resolve any replacement, security, or remote-state concerns.
4. Promote the approved change to `infra/prod`, adjusting only environment-specific values.
5. Release to prod only through the [release workflow](#release-workflow) and its [approval gates](#approval-gates).

Do not introduce new infrastructure directly in `infra/prod`. Production changes must have an equivalent, validated development change unless the [emergency process](#emergency-changes) is used.

## Region

All Terraform resources must be created in `us-west-2` wherever the resource type allows it. The only accepted exception is ACM certificates used by CloudFront, which AWS requires to be issued in `us-east-1`; use an `aws.us_east_1` provider alias, defined in each root, for that case only. Do not introduce additional regions or provider aliases without updating this rule.

## Release workflow

Owner decisions (2026-09-28):
- **CI holds no AWS credentials**, now or later.
- **Operator applies from the workstation.** Every Terraform apply and AWS rollout is run by the operator through IAM Identity Center with MFA.
- **Apply uses only a saved plan** that was reviewed and whose hash matches.

GitHub Environment required reviewers are not used as the gate. On Free, Pro, and Team plans they apply only to public repositories ([GitHub: deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)), and this repository is private under a user account.

```text
                ┌──────────── routine CI (no AWS credentials) ──────────┐
 PR / push ───► │ fmt -check · validate bootstrap/dev/prod (-backend=false)│
                │ Python lint/type/tests · import-boundary · route table   │
                │ build zips twice → identical → record hash manifest       │
                │ frontend lint/test/build (placeholder config) · scans     │
                └───────────────────────────┬──────────────────────────────┘
                                            │ commit green
 DEV  (operator, vp-dev-deployer)           ▼
  deploy-dev.sh publish        rebuild; hashes must equal CI's; create-only upload; ECR mirror by digest
  deploy-dev.sh plan           saved plan + risk summary
      ── operator reviews the summary ──
  deploy-dev.sh apply <plan>   type "dev" + plan-hash prefix; apply the saved plan
  deploy-dev.sh smoke
  deploy-dev.sh rollout-sites  assets, then index.html; invalidate index only
  deploy-dev.sh smoke          writes the dev release record (commit, manifest hash, smoke: pass)
      ── integrated dev verification ──
                                            │ commit on origin/main, CI green, dev record passed
 PROD (operator, vp-prod-deployer)          ▼
  deploy-prod.sh promote <sha> verify dev record; copy identical bytes and digests to prod stores
  deploy-prod.sh plan          read-only plan role; saved plan + risk summary
      ── operator reviews ──
  deploy-prod.sh approve <plan>  annotated tag prod/<YYYYMMDD>-<n> carrying the plan hash; pushed
  deploy-prod.sh apply <plan>    tag on HEAD must match; type "prod" + hash prefix; apply role
  deploy-prod.sh smoke → rollout-sites → smoke
 ROLLBACK
  Lambda/infra  plan with the previous release manifest → same approve/apply gates
  Sites         rollback-sites <sha> → re-upload that build's index.html; invalidate
  InvenTree     see InvenTree rollout
```

Terraform facts this workflow relies on:
- A saved plan applies without a confirmation prompt ([terraform apply](https://developer.hashicorp.com/terraform/cli/commands/apply)).
- It stores sensitive values in cleartext ([terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan)).
- Terraform rejects a saved plan as stale if the state has changed since planning.

The scripts therefore add their own confirmation, and plan files are handled as secrets.

## Deployment Scripts

Store deployment scripts in the root-level `scripts` directory. Keep scripts scoped to deployment automation and avoid placing reusable Terraform modules or environment root configurations there.

**Entry points.**
- `scripts/deploy-dev.sh <stage>` and `scripts/deploy-prod.sh <stage>`.
- Each script hardcodes its environment. Do not write one shared script parameterized by environment.
- A stage is required and has no default. Without one, the script prints usage and exits 2.
- `scripts/check.sh` (the CI checks) and `scripts/build-lambdas.sh` need no credentials and behave identically in CI and locally.

**Every environment script:**
- Uses `set -euo pipefail`.
- Before any Terraform or AWS call, it verifies:
  - that `aws sts get-caller-identity` shows the expected account and the environment's deployer role. Account IDs are per-environment inputs, never hardcoded in the script or in Terraform;
  - that the working tree is clean and HEAD is pushed to `origin`. Prod also requires HEAD to be reachable from `origin/main`;
  - the Terraform version.
- Passes `-input=false -lock-timeout=5m` to Terraform.
- Never runs a bare `terraform apply`, `-auto-approve`, `-target`, `destroy`, `state`, `import`, or `taint`.
- Never prints or persists secrets, state, raw plan JSON, or `*.tfvars`, and writes nothing inside the repository.
- Exit codes: 0 success, 2 usage, 3 identity or precondition failure, 4 checks failed, 5 Terraform error.

| Stage | Inputs | Effect | Changes AWS |
|---|---|---|---|
| `publish` (dev) | HEAD | Runs `build-lambdas.sh` and refuses if the zip hashes differ from CI's manifest for that commit. Uploads the zips and the release manifest create-only, and mirrors pinned image digests to dev ECR. | Inert create-only writes |
| `promote <sha>` (prod) | Dev release record for `<sha>`; CI status via authenticated `gh api` | Downloads each dev object, verifies its sha256, and puts it to the prod store with `If-None-Match`; copies images by digest. Fails closed if `gh` is unauthenticated or CI is not green. | Inert create-only writes |
| `plan` | Release manifest | Runs `terraform init` and `terraform plan -out` into the plan directory; runs the risk checker on `terraform show -json` in memory; prints the summary and the plan sha256. | Lock object only |
| `approve <plan>` (prod) | Plan file | Creates and pushes the release tag ([Approval gates](#approval-gates)). | No (git only) |
| `apply <plan>` | Plan file, typed confirmation, tag (prod) | Applies the saved plan, deletes the plan file, and writes the release record. | **Yes** |
| `rollout-sites` | `terraform output`; tag (prod) | Builds, scans, uploads, and invalidates ([Sequencing](#sequencing)). | **Yes** |
| `rollback-sites <sha>` | A stored site build | Re-uploads that build's `index.html` and invalidates. | **Yes** |
| `smoke` | `terraform output` | Read-only checks: catalog returns 200; protected and admin routes return 401 without a token; a webhook rejects an unsigned request; the CSP header is present; the projection freshness metric is current. | No |

**Risk checker.** It prints resource addresses and categories, never values. It flags:
- any delete or replace;
- ingress from `0.0.0.0/0` or `::/0`;
- a public IP on anything but the NAT instance;
- `publicly_accessible`;
- IAM policy or trust changes;
- resources under `prevent_destroy`;
- `desired_capacity`, launch-template, or engine-version changes;
- Secrets Manager secret versions;
- CORS-origin or authorizer changes.

A flagged dev plan needs an extra confirmation. A prod plan records its flags in the release tag.

## Approval gates

| Action | Routine CI | Operator (explicit invocation) | Extra prod requirement |
|---|---|---|---|
| `terraform fmt -check`, `validate` with `-backend=false`, lint, type checks, unit tests, builds, zip determinism, secret and dependency scans, documentation checks | ✅ | ✅ | – |
| Artifact publish or promote (create-only) | ❌ | ✅ | Dev release record; CI green |
| `terraform plan` (reads state) | ❌ | ✅ | Plan role only |
| IAM Access Analyzer `validate-policy` (needs credentials) | ❌ | ✅, in the `plan` stage | – |
| `terraform apply` of a saved plan | ❌ | ✅, with a typed confirmation | Release tag matching the plan hash |
| Site rollout and rollback | ❌ | ✅ | Release tag |
| Secret population and rotation | ❌ | ✅, by [runbook](#secrets) | Prod secrets permission set |
| InvenTree snapshot, migrate, instance refresh, restore | ❌ | ✅, by [runbook](#inventree-rollout) | Rehearsed in dev first |
| State changes (`import` or `moved` blocks) | ❌ | ✅, reviewed and applied as a saved plan | Release tag |
| `terraform state rm` | ❌ | Manual only, never scripted, with a recorded reason | Release tag |
| `terraform destroy` | ❌ | Not supported by the scripts | – |
| Dev start and stop, jumpbox capacity | ❌ | ✅ ([InvenTree integration](inventree-integration.md#dev-vs-prod-and-cost)) | – |

**Production approval record.**
- `deploy-prod.sh approve <plan>` creates an annotated tag `prod/<YYYYMMDD>-<n>` on the release commit and pushes it.
- The tag message records:
  - the plan sha256 and the release-manifest sha256;
  - the add, change, and destroy counts;
  - the risk-checker flags;
  - the operator's caller-identity ARN and the UTC time;
  - any emergency reason.
- Tags are signed when a signing key is configured. Unsigned annotated tags are allowed (owner decision, 2026-09-28).
- `apply` refuses unless `origin` holds a tag on HEAD whose plan hash equals the plan file's sha256.
- It then assumes the prod apply role with session name `apply-<first 12 hex of the plan hash>` and `SourceIdentity` set to the operator. CloudTrail therefore ties every API call to the plan and the person.
- Only the owner holds prod deploy rights, so there is no two-person rule. The tag and CloudTrail record are the accepted control.

## Credentials and permissions

**CI** (GitHub Actions):
- `permissions: contents: read` only.
- Never `id-token: write`, never AWS secrets, and no AWS role of any kind.
- Runs only the ✅ CI row of [Approval gates](#approval-gates).
- Records the Lambda zip hash manifest for each commit.

**Operators** use IAM Identity Center permission sets with MFA enforced. Both environments share one AWS account for now (owner decision, 2026-09-28):

| Permission set | Allows | Denies |
|---|---|---|
| `inventree-<env>-operator` | Jumpbox access only ([Staff access](inventree-integration.md#staff-access)) | Everything else |
| `vp-dev-deployer` | Read and write the dev state key and its lock; publish to dev artifact stores; plan and apply `infra/dev`; dev SSM Run Command and instance refresh for InvenTree upgrades | `prod/` state; prod-named or prod-tagged resources; prod secrets |
| `vp-prod-deployer` | Assume `${project}-prod-terraform-plan` (read-only, prod state read, lock write) and `${project}-prod-terraform-apply` (prod scope). Read dev artifact stores; create-only writes to prod artifact stores | Direct changes without an assumed role |
| `vp-secrets-operator-<env>` | `secretsmanager:PutSecretValue` on that environment's named secrets | Other environments; Terraform-managed resources |

- **Scoping:** by `${project}-<env>-*` names, `aws:ResourceTag/Environment`, and state key paths.
- **Lambda VPC conditions:** deploying principals keep the `lambda:SubnetIds` and `lambda:SecurityGroupIds` conditions from [Backend API](backend-api.md#iam).
- **Residual risk:** name and tag scoping is imperfect for IAM and global resources in a shared account.
- **Prod deploy rights:** the owner is the only holder of `vp-prod-deployer`.

## State, plans and artifacts

- **Remote state:**
  - `infra/bootstrap` creates one S3 state bucket with versioning, SSE, Block Public Access, a TLS-only policy, and `prevent_destroy`.
  - Roots use the S3 backend with `use_lockfile = true`. DynamoDB locking is deprecated ([S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3)).
  - Keys are `bootstrap/`, `dev/`, and `prod/`.
  - State is sensitive: only the deployer roles may read it.
- **Plan files:**
  - Treat them as secrets. Write them outside the repository, under `${XDG_STATE_HOME:-~/.local/state}/vitamin-packs/plans/<env>/`, with mode 0700.
  - Never upload them, attach them to CI, or paste them into a PR or issue.
  - Delete a plan file after its successful apply. Only its hash and summary persist, in the release tag or dev record.
  - `.gitignore` ignores `*.tfplan` as a backstop.
- **Deploy artifacts:**
  - One bucket per environment, `${project}-<env>-deploy-artifacts`, holds Lambda zips, release manifests, and site builds.
  - It is separate from the InvenTree artifacts bucket, which admits only the VPC endpoint.
  - It is versioned. Its bucket policy requires `If-None-Match` on uploads, which makes objects create-only. That policy also blocks `CopyObject`, so promotion re-uploads the objects ([S3 conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes-enforce.html)).
  - ECR repositories are tag-immutable ([ECR tag mutability](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html)).
- **Release manifest (`releases/<env>/<commit>.json`):**
  - Records the commit; each function's S3 key, hex sha256, and base64 sha256 (for `source_code_hash`); and the InvenTree and Caddy image digests.
  - It is the only `-var-file` for artifact inputs.
  - It is never committed: a commit would change the SHA recorded in each zip.

## Secrets

- **Terraform creates secret containers only.**
  - No `aws_secretsmanager_secret_version` and no `random_password` for a secret value.
  - RDS keeps `manage_master_user_password`.
- **Values are set out of band.** The operator runs `aws secretsmanager put-secret-value --secret-id <arn> --secret-string file://<path on tmpfs>` under `vp-secrets-operator-<env>`.
  - Values never appear on a command line, in shell history, in logs, or in the repository.
  - Delete the tmpfs file afterwards.
- **Environments:** dev uses sandbox provider credentials; prod uses live credentials.
- **Rotation:** follow [Secret rotation](inventree-integration.md#secret-rotation) and [Payment processing](payment-processing.md#secrets).

## Sequencing

Each release runs, in order:
1. Publish or promote artifacts. They are inert until an apply references them.
2. Plan, review, approve (prod only), then apply. This one apply changes infrastructure and Lambda code together.
3. Backend smoke tests.
4. Site rollout, storefront and admin independently.
5. Site smoke tests.
6. The release record.

Rules:
- **Backend before frontends.** API changes are additive ([Async job contracts](backend-api.md#async-job-contracts)).
- **Consumers before producers.** Terraform updates functions in no guaranteed order. A release must not add a job kind or field reader together with its first writer; split it into two releases.
- **DynamoDB backfills** are separate operator steps. They run dev first, after their reader is deployed, and must be idempotent.
- **Site rollout:**
  1. Build with configuration from `terraform output`, then scan the bundle for secrets.
  2. Upload hashed `assets/*` with immutable cache headers.
  3. Upload `index.html` last with `no-cache`.
  4. Invalidate only `/index.html` and `/`. Versioned file names are preferred over invalidation ([CloudFront](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Invalidation.html)).
  5. Never sync with `--delete`. Prune assets more than three releases old.
  6. Store each build under `sites/<env>/<app>/<commit>/` for `rollback-sites`.
- **Rollback.** A Lambda or infrastructure rollback is a new plan using the previous release manifest, and it passes the same gates. A site rollback is `rollback-sites <sha>`.

## InvenTree rollout

An InvenTree image or configuration change is always its own release, never bundled with application changes. [Health, Deployment and Persistence](inventree-integration.md#health-deployment-and-persistence) defines the host procedure; this section fixes how Terraform fits into it.

- **No `instance_refresh` block on the InvenTree Auto Scaling group.** The AWS provider always starts a refresh when `launch_template` changes ([aws_autoscaling_group](https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/autoscaling_group.html.markdown)). An apply would then replace the host before migrations ran.
  - Pin the launch-template version.
  - The operator starts the refresh explicitly.
- **Upgrade order** (dev first):
  1. Publish or promote the image digest.
  2. Plan and review (prod: approve) the launch-template change **before** the outage starts. The plan must touch only the launch template and the Auto Scaling group.
  3. Take a manual RDS snapshot and confirm media versioning is on.
  4. Stop the worker.
  5. Run the one-off `invoke migrate` with the new digest through SSM Run Command.
  6. Apply the saved plan; no host is replaced.
  7. Start an instance refresh with `MinHealthyPercentage` 0.
  8. Smoke-test: health, the worker heartbeat, an inventory-sync run, and the client contract tests.

  Steps 3–8 must fit inside the 20-minute [freshness limit](inventree-integration.md#sync-and-freshness).
- **Configuration-only change:** plan and apply, then an operator refresh.
- **Rollback:**
  - If no migration ran, or the schema is still compatible, re-plan with the previous digest, then refresh.
  - Otherwise use the [restore procedure](inventree-integration.md#rds-postgresql).
- **After a restore, reconcile Terraform.** A restore always creates a new RDS instance (or DynamoDB table). Bring it into state with an `import` block in a reviewed plan, then retire the old resource with a final snapshot.
- **Capacity drift:** give every Auto Scaling group whose capacity the scheduler or operator manages `ignore_changes = [desired_capacity]`. That covers the jumpbox in both environments, and the InvenTree host and NAT instance in dev. An apply must never resize a running jumpbox or wake a stopped dev environment.

## Emergency changes

- `deploy-prod.sh plan --emergency "<reason>"` and `approve --emergency "<reason>"` skip only the dev-release-record precondition.
- The reason is recorded in the release tag. Every other gate still applies.
- An equivalent dev change must be applied within **2 days** (owner decision, 2026-09-28).

## Moving prod to another account

Prod runs in the owner's current AWS account alongside dev. The owner may later move prod to a separate, business-owned account. To keep that move cheap:
- Never hardcode account IDs. Keep state, artifact buckets, and ECR repositories per environment.
- Rebuild these per-account items in the new account:
  - the SES domain identity and DKIM records;
  - the public hosted zone, or its delegation, which the prod root reads as a data source;
  - IAM Identity Center permission sets and CloudTrail;
  - the state bucket (bootstrap);
  - the EC2 Instance Savings Plan.
- Move data with the documented restores (RDS snapshot, S3 media, DynamoDB export). Secrets are re-populated, never copied from state.

## Acceptance tests

Run these in dev once the scripts and CI exist:
- Running `deploy-prod.sh` with no argument, or with dev credentials, exits before any Terraform or AWS call.
- `apply` refuses:
  - a missing plan;
  - an edited plan (hash mismatch);
  - a prod plan with no matching pushed tag;
  - a stale plan, after an intervening apply.
- Re-uploading an existing artifact key fails with a 412 precondition failure. Pushing an existing ECR tag fails.
- Applying a launch-template change starts no instance refresh (`describe-instance-refreshes` is empty).
- After the nightly dev stop, a no-op plan shows no `desired_capacity` change.
- The risk checker flags a seeded `0.0.0.0/0` rule and a seeded replacement without printing values.
- `rollback-sites` restores the previous `index.html`.
- CloudTrail shows the apply session `apply-<hash12>` with the operator's `SourceIdentity`.
- `git status` is clean after every stage.
- CI workflow files contain no `id-token: write` and no AWS secrets.

## Terraform Conventions

Follow the repository's [Terraform conventions](terraform-conventions.md) for module structure, validation, naming, tags, and safety requirements.
