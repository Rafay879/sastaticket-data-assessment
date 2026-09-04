# Senior Data Engineer — Hands-on Task

Take the day. There's no timer running — work at whatever pace suits you, and
take breaks whenever you want.

## The situation

You have joined the data team at an online travel agency. Bookings arrive from
two very different upstream systems:

- `gds_bookings` — bookings made through the GDS (Sabre-style). Newline-
delimited JSON, written by a service that has been running for years and has
been modified more than once along the way.
- `lcc_bookings` — bookings made through low-cost carriers' direct-connect
APIs. Also newline-delimited JSON, but built by a different team with
different conventions.

Both feeds are **append-only event logs**. A booking reference can appear more
than once in a file. Payments come from the gateway in `payments.csv`, also as
an event log.

We haven't documented the field-level schemas. Profiling the files is part of
the task.

Commercial has been building this number by hand in a spreadsheet every week and
wants it automated.

## What we want

Build a table that answers:

> **Net confirmed bookings and net revenue, by airline, by departure date.**

Definitions we can give you:

- **Net** — count only bookings whose *latest known state* is confirmed. A
booking that was later cancelled does not count, and neither does its revenue.
- **Revenue** — the total fare on the booking (base + tax, or the equivalent
field in the other feed), expressed in **PKR**, converted at the rate for the
date the booking was made.
- **Departure date** — the **local calendar date at the origin airport**. Not
UTC, and not the booking date. For a multi-leg booking, use the first leg.

Output columns:

```
airline_code | departure_date_local | net_confirmed_bookings | net_pax | net_revenue_pkr
```

Anything we have *not* defined is a judgement call. Make it, and write down why.

## Results

From `fct_net_bookings_by_airline_departure_date` (`dbt build --select marts`),
across the whole table:

- **Total net confirmed bookings: 713**
- **Total net revenue: PKR 90,072,854.75**

See `ASSUMPTIONS.md` for how "net" was interpreted and every other judgement
call behind these numbers.

## What you're given

```
data/raw/          gds_bookings.json, lcc_bookings.json, payments.csv, search_logs.csv
reference/         airports.csv, airlines.csv, fx_rates.csv, status_codes.csv
dbt/               a working dbt-duckdb project with sources wired up and one
                   worked example model (stg_payments)
```

`search_logs.csv` is **not** needed for the metric. It's there for a discussion
later on.

## How to run

Locally:

```bash
cd dbt
dbt build          # should succeed out of the box; if it doesn't, tell us
```

Containerized:

```bash
docker build -t assessment .
docker run --rm assessment
```

Everything runs locally against DuckDB. No cloud account, no credentials.

## Known gaps

Things not done, or done with lower confidence, in rough order of how much
they'd change the numbers:

- **LCC null-currency default and the ms-vs-s timestamp fix are inferred
  from profiling, not confirmed with the source teams.** Defaulting null
  `currency` to PKR and detecting millisecond epochs by magnitude
  (`> 100000000000`) both work on this dataset but are guesses at the real
  cause. See "who I'd ask" in `ASSUMPTIONS.md`.
- **The cross-feed dedup rule (carrier's home feed wins) is inferred from
  6 observed duplicate bookings**, not a documented rule from whoever owns
  the GDS/LCC integrations. It's plausible and it works on this data, but
  it's a guess, not a confirmed spec.
- **`rpt_payment_reconciliation` surfaced a likely double-capture** on
  booking `S86X7Y` (settled ≈2x the fare) that was flagged, not
  investigated or corrected - it's a QC report, not a fix.
- **No test enforces that every `origin` airport has timezone coverage** in
  `stg_airports` - `int_bookings_local_departure` currently resolves for
  every row in this dataset, but a future origin missing from the
  reference table would silently produce a `null` `departure_date_local`
  rather than erroring.
- **`search_logs.csv` is untouched**, per the README's own scope note.
- **No incremental materialization strategy** - every model rebuilds from
  full source data on every run. Fine at this volume; would need
  revisiting well before 50x scale.
- **Bonus sections (B1 cloud run plan, B2 IaC) were not attempted** - the
  core pipeline, its tests, and this documentation were the priority.

## What to hand in

Either is fine:

- **A GitHub repository on your own account** (private is fine — just add the
reviewers we give you), or
- **A zip file** of your working directory.

If you use git, commit as you go rather than in one lump at the end. We do read
the history, but this is a preference, not a requirement.

Whichever you choose, include:

1. **The models.** Bronze → silver → gold, or whatever layering you prefer, as
  long as the reasoning is visible.
2. **Tests.** dbt tests, singular tests, or both. We care more about *what* you
  chose to test than how many tests there are.
3. **A** `Dockerfile` that runs `dbt build` in a container.
4. `ASSUMPTIONS.md`**.** Every judgement call you made, and what you'd do
  differently with more time or with someone to ask. This is read as carefully
   as the SQL.
5. **The headline numbers** — total net confirmed bookings and total net revenue
  — in the README.



## Ground rules

- **Ask us anything.** Someone from the team is available all day. Asking good
questions counts in your favour, not against you.
- **The data is messy.** Deliberately so, in the ways real feeds are messy. Part
of the task is noticing that.
- **Use Claude.** Not just allowed — preferred. We use it across the engineering team and we'd rather see how you work with it than watch you type SQL from memory. Claude Code, whatever you're used to. You'll walk us through your code afterwards and explain the choices, so use it the way you'd use it on the job.
- **Finishing everything is not the bar.** We would much rather see three
correct, well-tested models and a clear list of known gaps than a complete
pipeline you can't vouch for.



## Bonus (optional)

Only if the core task is done and you're happy with it. **Nobody is marked down
for skipping this**, and a solid core with no bonus beats a rushed core with
one.

**B1 — Cloud run plan (**`DEPLOYMENT.md`**).** How would you run this pipeline in
production on AWS? Name the services and say why each one. Cover roughly:

- Where the raw feeds land and in what format
- What executes the dbt run, and what triggers it
- Where the modelled tables live and what queries them
- How you'd handle a failed run, and how you'd know it failed
- What it would cost per month at roughly 50× this data volume, and where the
money actually goes

We care more about the reasoning than the diagram. If you'd choose the cheaper
option over the more capable one, say so and say why. If two services would both
work, tell us what would make you pick one.

**B2 — Infrastructure as code.** A working skeleton of the above — Terraform,
CloudFormation, or even shell scripts calling the AWS CLI. It does not need to
be complete or deployable; we'd rather see a well-scoped IAM policy and a
correct task definition than a full environment with `"Action": "*"` in it.

Be ready to explain why each permission you granted is there.