# Terraform (B2 — Infrastructure as Code)

## What this is

This is the **B2 bonus** deliverable: a Terraform skeleton of the
architecture described in `DEPLOYMENT.md` (B1). It is **not deployable
as-is** - see "What's NOT here" below. The goal is to show a well-scoped
IAM policy and a correct task/state-machine definition, not a full
production environment.

## What's real vs. stub

| Component | Level | Notes |
|---|---|---|
| IAM policies | Fully specced, every statement commented | The reviewer's focus per the assessment |
| ECS Fargate task definition | Fully specced | Complete CPU/mem/log config |
| Step Functions state machine | Fully specced JSON | Parallel, Choice, Retry, Catch |
| S3 buckets | Full: policy, versioning, Intelligent-Tiering, KMS encryption | |
| DynamoDB, SNS, EventBridge, Glue Crawler | Fully specced but minimal | |
| Lambda handlers | Python stub with real signature/docstring | Business logic omitted; role, env, wiring are real |
| VPC/networking | Deliberately skipped | Uses default VPC; separate module in reality |

## How to review

Where to look first, roughly in reviewing priority order:

1. `policies/` - the IAM policies. This is where the least-privilege
   reasoning lives.
2. `modules/compute/` - the ECS Fargate task definition that runs
   `dbt build`.
3. `modules/orchestration/` - the Step Functions state machine.

## How it maps to DEPLOYMENT.md

- **Section 1** (where raw feeds land, in what format) → `modules/storage`
  (bronze/silver/gold S3 buckets) + `modules/ingestion` (the four Lambdas
  under `lambdas/`).
- **Section 2** (what executes the dbt run, what triggers it) →
  `modules/compute` (the Fargate task definition) + `modules/orchestration`
  (the Step Functions state machine and its EventBridge schedule).
- **Section 3** (where the modelled tables live, what queries them) →
  `modules/catalog` (Glue database + crawler).
- **Section 4** (handling a failed run, knowing it failed) →
  `modules/monitoring` (SNS topic + alarms).
- **Section 5** (monthly cost at ~50x volume) → lives in `DEPLOYMENT.md`
  itself, not in this IaC - it's a cost estimate, not a resource.
- **Section 6** (dbt version/config) → lives in the container image built
  from the repo root `Dockerfile`, not in this IaC - Terraform just points
  the Fargate task definition at that image.

## Bootstrap

Terraform state itself needs somewhere to live before `terraform init` can
run against the S3 backend in `main.tf`. In order:

1. Create the tfstate S3 bucket and the `sastaticket-terraform-locks`
   DynamoDB table by hand (or with a small bootstrap script) - this is the
   one piece of infrastructure not managed by this Terraform config, since
   it has to exist before Terraform has anywhere to store state.
2. Fill in `bucket = ""` in `main.tf`'s `backend "s3"` block with that
   bucket's name.
3. Run `terraform init`.

## What's NOT here

- A VPC/subnet module - this skeleton assumes the default VPC. A real
  deployment would isolate the Fargate task and Lambdas in private
  subnets with a NAT gateway, as its own module.
- Fully written KMS key policies - S3 encryption uses AWS-managed keys
  (`aws/s3`) as a placeholder rather than a customer-managed key with its
  own key policy.
- A CI/CD pipeline for applying this Terraform config.
- The actual Lambda ingestion business logic (API calls, watermark
  read/write, Parquet writing) - see the docstring in each
  `lambdas/*/handler.py` for what the production version would do.
- Environment-specific `.tfvars` files for dev/staging - only the
  defaults in `variables.tf` exist today.
