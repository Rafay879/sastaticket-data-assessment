# Deployment (B1 — Cloud run plan)

How this pipeline would run in production on AWS. The `terraform/`
directory (B2) is a partial skeleton of what's described here — see
`terraform/README.md` for exactly which pieces are real Terraform vs.
stubs, and for the section-by-section mapping back to this document.

## 1. Where raw feeds land, and in what format

Four sources - GDS bookings, LCC bookings, payments, and reference data -
are pulled by four scheduled Lambda functions (`terraform/lambdas/`) and
landed as **Parquet** in an S3 **bronze** bucket, partitioned by
`<source>/created_date=YYYY-MM-DD/`. Each Lambda tracks its own
last-processed timestamp in a shared DynamoDB **watermarks** table
(`source_name` as the key), advancing it only after a successful write -
so a failed run is safe to retry without skipping or duplicating records.

Bronze, plus **silver** (staged/intermediate dbt tables) and **gold**
(mart output) buckets, all get versioning, SSE-S3 encryption, a
public-access block, and a bucket policy denying non-TLS requests. Bronze
additionally gets S3 Intelligent-Tiering (default tiers only) since it's
read repeatedly (by the crawler, and by dbt); silver/gold don't get it yet
- see section 6.

**Why S3 + Lambda + DynamoDB, not something heavier:** the ingestion
volume here is small and bursty (four sources, once a day), which is
exactly Lambda's shape. A watermark in DynamoDB is the simplest reliable
way to make each run incremental without standing up a queue or a
change-data-capture pipeline neither source system offers.

## 2. What executes the dbt run, and what triggers it

An **EventBridge** rule fires daily at 02:00 UTC (`var.schedule_expression`,
a `cron(...)` expression - swappable to `rate(1 hour)`), starting a
**Step Functions** state machine (`terraform/modules/orchestration`):

1. **IngestSources** (Parallel) - invokes all four ingestion Lambdas at
   once. Each branch retries transient Lambda service errors (not
   application errors) up to 3 times before the whole Parallel state is
   caught and routed to failure notification.
2. **AggregateIngestResults** - sums `new_records` across all four
   branches.
3. **NewDataArrived** (Choice) - if nothing new arrived anywhere, skip
   straight to a no-op success rather than paying for a crawl + dbt run
   with nothing to process.
4. **RunCrawler** - starts the Glue crawler over bronze, then polls until
   it reports `READY`.
5. **RunDbtBuild** - runs the dbt image (built from the repo-root
   `Dockerfile`) as an **ECS Fargate** task via the synchronous
   `ecs:runTask.sync` integration, which waits for completion and fails
   the state on a non-zero container exit code.
6. Any failure at any stage publishes to an SNS topic with the error and
   cause, then fails the execution (section 4).

**Why Fargate, not Lambda, for the dbt run itself:** dbt needs to run
longer than Lambda's practical comfort zone for a bundled image with
DuckDB/Athena drivers, and doesn't need to scale horizontally - a single
short-lived container on a schedule is a better fit than a maxed-out
Lambda timeout. **Why Step Functions, not just an EventBridge-triggered
Lambda chain:** the pipeline has real branching (skip if no new data),
retry semantics, and a fan-out/fan-in step (four parallel ingestions) -
Step Functions makes that graph explicit and visible in the console,
instead of encoding it as ad-hoc Lambda-to-Lambda invocations.

## 3. Where the modelled tables live, and what queries them

Silver and gold tables are written as **Iceberg** tables directly by
dbt-athena (via `dbt build` inside the Fargate task), registering their
own schema in the **Glue Data Catalog** (`sastaticket_prod` database) -
no crawler needed for tables dbt itself owns. Bronze is the one thing a
**Glue crawler** does need to catalog, since its schema comes from
whatever the upstream feeds happen to produce, not from a dbt model
definition.

Queries run through a dedicated **Athena workgroup**
(`enforce_workgroup_configuration = true`, so query output always lands
in one known results bucket regardless of what a client requests). In
production this is what a BI tool (QuickSight, or any Athena-compatible
client) would point at for `fct_net_bookings_by_airline_departure_date`.

## 4. Handling a failed run, and knowing it failed

Every failure-prone state (`IngestSources`, `RunCrawler`, `RunDbtBuild`)
has a `Catch` routing to a `NotifyFailure` task that publishes a
structured message (which state failed, `Error`, `Cause`) to an **SNS**
topic with an email subscription. That covers a run that starts and fails
loudly.

For a run that fails silently - EventBridge doesn't fire, or the state
machine never starts - a **CloudWatch alarm** watches the
`AWS/States ExecutionsSucceeded` metric for the state machine: if it
hasn't recorded at least one success in a 24h window, the alarm fires
regardless of *why* (`treat_missing_data = "breaching"`, so "no data at
all" counts as broken, not "nothing to alarm on"). This dead-man's-switch
is the difference between "the pipeline failed" and "the pipeline simply
never ran," which a loud-failure-only design would miss entirely.

## 5. Cost per month at ~50x this data volume

The assessment's dataset is small - roughly 900 bookings landed over the
~2-month window in `data/raw/`, call it ~1,100 bookings/month. At 50x,
that's **~55,000 bookings/month**: still a small pipeline by AWS
standards, mostly serverless/on-demand services well under any capacity
tier, so the honest answer is "a few dollars a month," not a line-item
budget worth agonizing over.

| Service | Usage at ~55K bookings/month | Monthly cost |
|---|---|---|
| S3 (bronze + silver + gold + athena-results) | ~15 GB accumulated, Intelligent-Tiering | ~$0.60 |
| DynamoDB (watermarks) | PAY_PER_REQUEST, ~200 requests/month | ~$0.05 |
| Lambda (4 ingestion functions) | ~120 invocations/month, 512 MB, seconds each | ~$0.05 (within free tier) |
| Secrets Manager (2 secrets) | 2 secrets x ~$0.40/secret/month | ~$0.80 |
| ECS Fargate (dbt build) | 2 vCPU, 4GB, ~2 min/day x 30 | ~$1.20 |
| Glue Crawler (bronze) | 2 DPU, 10-min billing minimum, ~20 runs/month | ~$1.75 |
| Athena (dbt-athena queries) | Small scans - Iceberg + date partitioning keep most queries pruned to a handful of partitions | ~$0.15 |
| CloudWatch Logs/alarms + SNS + EventBridge | Minimal log volume, 1 alarm, near-zero email volume | ~$0.10 |
| **Total** | | **~$5/month** |

**Where the money actually goes:** at this volume, almost nothing is
driven by data size - it's driven by fixed per-run minimums. Glue
Crawler's 10-minute billing floor per run and Secrets Manager's flat
per-secret fee both cost more than moving the actual bytes. ECS Fargate
is cheap specifically because the task only runs for ~2 minutes a day;
that assumption is the one most worth re-checking as the model count and
build time grow, since Fargate is billed by the second while running, not
by data volume - see the sizing note in
`terraform/modules/compute/main.tf`.

**Schedule sensitivity:** the numbers above assume the default daily
cadence. Running hourly instead (`rate(1 hour)`) would take Fargate alone
from ~$1.20/month to ~$28/month if every hourly trigger actually ran a
build (24x the daily run count, since Fargate cost scales linearly with
the number of runs). In practice the Step Functions `NewDataArrived`
Choice-state skip means most hourly checks find nothing new and skip the
crawl + dbt build entirely - with that skip active for most hours, hourly
cadence stays in the ~$15-20/month range rather than the full unguarded
~$28. Either way, cost is not the reason to avoid hourly at this data
volume; freshness-vs-complexity is the real tradeoff (see "what I'd do
differently" framing in `ASSUMPTIONS.md` for the same style of judgement
call).

## 6. dbt version/config

dbt's version, adapter, and profile configuration live in the repo-root
`Dockerfile` and `dbt/` project files - the image is what actually defines
"what dbt does," and Terraform's only job is to point the ECS task
definition at that image (`image = "${ecr_repo_url}:latest"`, with a
comment that production would pin a specific tag/SHA instead). This keeps
a dbt upgrade or profile change as a container rebuild + redeploy, not a
Terraform change.

The one adaptation this assessment's local setup doesn't cover: locally,
`dbt/profiles.yml` targets **dbt-duckdb** reading CSV/JSON directly off
local disk. In production, sources are Parquet in S3 registered in Glue,
queried through Athena - so the production image needs a **dbt-athena**
profile instead, not just the same DuckDB profile pointed at S3. The
Fargate task role's IAM permissions
(`policies/fargate_dbt_task.json` - `GlueCatalogAccess`, `AthenaExecute`,
`AthenaWorkgroupRead`, `AthenaResultsBucket`) already assume dbt-athena;
writing that profile and confirming the staging/intermediate/marts models
compile unchanged under it is real follow-up work, not yet done here.

Marts currently use full-rebuild (table) materialization, which is why
silver/gold don't have Intelligent-Tiering enabled yet (section 1) - every
run rewrites the same objects, so tiering by *last accessed* wouldn't
reflect real access patterns until incremental materialization lands.
