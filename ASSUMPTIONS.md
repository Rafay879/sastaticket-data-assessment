# Assumptions & Judgement Calls

## Staging layer

### GDS booking record shapes (`stg_gds_bookings`)

`raw.gds_bookings` contains two different record shapes, presumably from two
generations of the upstream service:

- **Flat shape**: `flight_no`, `origin`, `destination`, `departure_local` are
  columns directly on the record.
- **Segments shape**: those four fields are absent; instead there is a
  `segments` array of structs, each with `seq`, `flight_no`, `origin`,
  `destination`, `departure_local`.

`stg_gds_bookings.sql` normalizes both into one flat shape:

- For segments-shape rows, the segment with the lowest `seq` is used
  (via `arg_min(field, seq)`, not by assuming the array is pre-sorted or
  that leg 1 is always at index 0 — both would break silently if a future
  load ever arrives out of order).
- For flat-shape rows, the flat columns are used directly via `coalesce`.
- `leg_count` is the number of elements in `segments` when present, else `1`.
- The two shapes are assumed to be mutually exclusive per row (a row never
  has both `segments` and the flat columns populated). This held for every
  row profiled; if it turns out to be false for some rows, the current
  `coalesce` silently prefers the flat value, which may not be desired if
  `segments` is judged authoritative when both are present.

This is staging-only normalization (shape unification), not business logic:
no deduplication of repeated `pnr` events and no status-code translation
happens here. That's deferred to the intermediate layer.

### LCC bookings deferred issues (`stg_lcc_bookings`)

Two problems were identified while profiling `raw.lcc_bookings` but
deliberately **not fixed at the staging layer**, to keep staging a thin,
lossless cast/rename of the source. Both need to be resolved before the LCC
feed can be safely unioned with GDS in the intermediate layer:

- **Null `currency`**: ~6% of records (41 of 658 profiled) have no
  `currency` key at all, which `read_json_auto(..., union_by_name=true)`
  surfaces as `null`. Staging passes this through as `currency` (nullable),
  with no default applied. The intermediate layer will need a rule for
  what currency to assume for these rows (candidates: infer from `route`
  and airport reference data, infer from `airline_code`, or default to PKR
  since PKR dominates the feed) before revenue can be converted correctly.
- **Mixed `departure_utc` unit**: most values are 10-digit Unix seconds,
  but some rows carry 13-digit millisecond epoch values (e.g. a raw value
  of `1790715900000` vs. the seconds range of `1778051700`-`1787438020`
  seen elsewhere in the same column). Staging casts `departure_utc` to
  `bigint` and passes it through unchanged as `departure_utc_raw` — no unit
  normalization. The intermediate layer must detect the unit per-row
  (e.g. by magnitude: treat anything above a sane seconds-range threshold,
  such as year 2200 in seconds, as milliseconds) before converting to a
  timestamp, otherwise millisecond rows will resolve to nonsense dates
  centuries in the future.

## Intermediate layer

### Latest-state collapse and `booking_made_at` (`int_gds_bookings_latest`, `int_lcc_bookings_latest`)

Both feeds are append-only event logs (a `pnr` / `booking_reference` can
appear many times as its state changes). Each intermediate model collapses
to one row per booking via `row_number() over (partition by <key> order by
<event_ts> desc)`, keeping `rn = 1` - i.e. the *latest known state* wins,
per the README's definition of "net". Separately, `booking_made_at` is
computed as `min(<event_ts>)` **per key, over all rows**, in the same
windowed pass, before the `rn = 1` filter - so it reflects when the booking
was first created even though every other output column reflects the
latest event. This matters because revenue must be converted to PKR "at the
rate for the date the booking was made" (README), not the date it was last
updated. GDS: 386 distinct pnrs after collapsing. LCC: 520 distinct
booking_references after collapsing.

### LCC timestamp-unit fix (`int_lcc_bookings_latest`)

Confirmed the mixed-unit issue flagged in staging is real and applied the
fix here: any `departure_utc_raw > 100000000000` (i.e. a 13-digit
millisecond epoch, since second-epoch values in this data are 10 digits) is
divided by 1000 before conversion to a timestamp. **15 of the 520
latest-state LCC rows** were affected. This is a magnitude heuristic, not a
per-record unit flag from the source - see "what I'd do differently" below.

### LCC currency default (`int_lcc_bookings_latest`)

Null `currency` (41 raw records / 34 of the 520 latest-state rows, after
collapsing to one row per booking) is defaulted to `'PKR'` via
`coalesce(currency, 'PKR')`, since PKR is overwhelmingly the dominant
currency in the feed and no other signal (route, airline) reliably predicts
currency for these specific rows. The null-ness is **not discarded**: a
`currency_was_defaulted` boolean survives into `int_bookings_unioned` (GDS
rows get `currency_was_defaulted = false`, since GDS never has a null
currency in the source) so a downstream test or audit can flag/exclude
defaulted rows without having to re-derive which ones they were.

### Cross-feed dedup (`int_bookings_unioned`)

Profiling turned up bookings on GDS-native carriers (PK/Pakistan
International, PA/AirSial, ED/Airblue) that also appear in the LCC feed
under the **same booking reference**, same flight, same fare - i.e. the
same real-world booking captured by both upstream systems, not a
coincidental key collision. Confirmed **6 such pnrs** across the full
dataset: `TDTBZR` (PK), `W5376V` (ED), `53NJZ1` (PK), `28VNRL` (PK),
`GLPH40` (ED), `BSFCYX` (PA).

The fix: join each row's `carrier` to `stg_airlines.feed` to get that
carrier's home feed, and for any `pnr` present in both `source_feed`s, keep
only the row whose `source_feed` matches the carrier's home feed, dropping
the other. This took the union from 386 + 520 = 906 rows down to **900**
(6 dropped), matching the 6 pnrs found above exactly. Carriers with no
match in `stg_airlines` are kept as-is (no basis to drop either copy).

### Timezone handling for departure date (`int_bookings_local_departure`)

Per the README, departure date must be the **local calendar date at the
origin airport**, not UTC and not the booking date. The two feeds needed
opposite treatment:

- **GDS** (`departure_local_raw`): already recorded as local wall-clock
  time in the source (no offset/zone attached) - taken as-is, just cast to
  a date. No conversion, because there is nothing to convert from.
- **LCC** (`departure_utc_normalized`): recorded as a UTC epoch - converted
  to the origin airport's IANA timezone (from `stg_airports.timezone`, via
  the `icu` DuckDB extension) with `AT TIME ZONE`, then cast to a date.

This relies on `stg_airports.timezone` covering every `origin` seen in the
bookings feeds; not explicitly re-verified with a test at this layer (see
"what I'd do differently").

### FX conversion (`int_bookings_fx_converted`)

Joined to `stg_fx_rates` on `(currency = fare_currency, rate_date =
date(booking_made_at))`. No special-case was needed for PKR - `fx_rates.csv`
already carries a `PKR, 1.0` row for every date, so PKR bookings get
`pkr_per_unit = 1.0` through the same join as any other currency. Where no
matching `(currency, date)` row exists, `fare_amount_pkr` is left `null`
and `fx_rate_missing = true` is set, rather than the row silently vanishing
from a revenue sum. In this dataset, **0 of 900 rows** hit a missing rate -
`fx_rates.csv` covers 2026-05-01 through 2027-01-16, which fully spans the
observed `booking_made_at` range (2026-05-01 to 2026-07-01) - so the flag
exists as a safety net for future data rather than because current data
needs it.

### Orphaned payments (`int_payments_orphaned`)

**25 of 1,086** payment events have no matching booking in either feed
after dedup (left join on `booking_ref = pnr`, keeping only the unmatched
side). Not part of the core metric; kept as a separate model rather than
silently dropped by an inner join elsewhere in the pipeline, so it's
available for a follow-up investigation into why the gateway saw a payment
with no corresponding booking record.

## Marts layer

### Net definition (`fct_net_bookings_by_airline_departure_date`)

"Net" is read literally per the README: only bookings whose *latest known
state* is `CONFIRMED` count. That means **both** `PENDING` (40 bookings -
never ticketed, no revenue) and `CANCELLED` (147 bookings) are excluded,
not just `CANCELLED` - a booking that was never confirmed shouldn't count
any more than one that was confirmed and later cancelled. Of 900 unioned
bookings: 713 `CONFIRMED`, 147 `CANCELLED`, 40 `PENDING`.

### Payment reconciliation FX basis (`rpt_payment_reconciliation`)

Both sides of the billed-vs-settled comparison are converted to PKR using
the FX rate for the booking's `booking_made_at` date, not the payment
event's own date. This is a deliberate choice for a *data-quality* check:
using two different FX dates would make ordinary FX drift between booking
and payment look like a settlement variance, which would defeat the
report's purpose. For actual cash-received revenue accounting, payment-date
FX would be the correct basis instead - noted in the model's header comment
so it isn't mistaken for the "real" revenue rate.

When a booking has no payment rows at all, `settlement_currency` falls back
to the booking's own `fare_currency` so the FX join still resolves (44 of
713 confirmed bookings currently have no captured payment at all -
`has_any_captured = false` - exactly the case that flag exists to let a
downstream test exclude, per the prompt).

Spot-checking the largest variances surfaced a genuine anomaly worth
flagging rather than fixing here: booking `S86X7Y` shows `net_settled_pkr`
at roughly 2x `fare_amount_pkr` (534,534.32 vs 267,267.16), consistent with
a duplicate/double capture at the gateway. This is exactly the kind of
issue the reconciliation report exists to surface - no correction has been
applied to the data.

**Correction, made after initially assuming otherwise:** all 9 originally-
flagged variances turned out to already be `CONFIRMED` bookings - none were
cancelled-with-refund. `assert_payment_reconciliation_within_tolerance.sql`
now filters explicitly on `canonical_status = 'CONFIRMED'` anyway (defense-
in-depth, since `rpt_payment_reconciliation` is already CONFIRMED-only
upstream), and `canonical_status` / `currency_was_defaulted` were added as
output columns on `rpt_payment_reconciliation` so this is checkable
directly instead of by ad-hoc join. Digging further split the 9 into two
distinct root causes:

- **7 bookings** (incl. `S86X7Y`) where `net_settled_pkr` is exactly 2x
  `fare_amount_pkr` - the double-capture pattern above.
- **2 bookings** (`WTZB55`, `0LL2P5`) where `currency_was_defaulted = true`
  - their `fare_amount_pkr` baseline is itself wrong (fare defaulted to
    PKR at a trivially small numeric value, e.g. `371.60`), while the
    actual gateway payment came through in AED for a matching native
    amount. This isn't a settlement problem at all - it's the null-
    currency-default assumption very likely being wrong for these two
    specific bookings, already surfaced separately by
    `assert_currency_default_visibility.sql`.

The test now excludes `currency_was_defaulted` bookings, since counting
them here too would double-report the same root cause under a misleading
"settlement variance" label. Warn count: **9 → 7**, isolating the
double-capture-shaped anomalies specifically.

## Headline numbers

Computed from `fct_net_bookings_by_airline_departure_date` after
`dbt build --select marts`:

- **Total net confirmed bookings: 713**
- **Total net pax: 1,392**
- **Total net revenue: PKR 90,072,854.75**

## Testing strategy

`dbt build` runs 37 tests total: 15 schema tests (staging + marts) and 6
singular tests in `dbt/tests/`. Result: **PASS=35, WARN=2, ERROR=0** - the
two warnings are intentional (see below), nothing is broken.

Schema tests on `fct_net_bookings_by_airline_departure_date` cover
mechanical correctness (composite uniqueness on `(airline_code,
departure_date_local)`, not-null on every output column, and referential
integrity of `airline_code` against `stg_airlines` via `relationships` -
the dynamically-correct equivalent of "accepted values from a reference
table", since `accepted_values` only supports a static list). The
composite-uniqueness test uses a small custom generic test macro
(`macros/test_composite_unique.sql`) rather than pulling in the `dbt_utils`
package, to keep the project dependency-free and fully offline, matching
"no cloud account, no credentials" in the README.

Each singular test targets a specific piece of messiness found while
profiling this dataset, not generic coverage:

- **`assert_no_cancelled_bookings_in_marts.sql`** - the README states this
  requirement explicitly ("a booking that was later cancelled does not
  count"), so it's the most direct test to get wrong silently: an
  off-by-one in the `canonical_status` filter would inflate both the
  booking count and the revenue total without any visible error. The test
  independently recomputes the CONFIRMED-only count for every slice that
  contains a CANCELLED booking and diffs it against the mart. Passes on 0
  rows.
- **`assert_no_pending_bookings_in_marts.sql`** - excluding `PENDING`
  (never ticketed, no revenue) is *our* judgement call, not something the
  README spells out, so it gets the same independent-recompute treatment
  as CANCELLED rather than assuming the one test above also covers it.
  Passes on 0 rows.
- **`assert_no_cross_feed_double_count.sql`** - directly tests judgement
  call #1 from the intermediate layer: the 6 real bookings found leaking
  across both feeds under the same `pnr` (see "Cross-feed dedup" above).
  If the dedup logic in `int_bookings_unioned` ever regresses, this is
  the test that catches a booking being counted twice. Passes on 0 rows.
- **`assert_fx_conversion_complete.sql`** - guards against the specific
  failure mode of `sum(fare_amount_pkr)`: a missing fx rate produces
  `null`, which `sum()` silently ignores rather than erroring, so revenue
  could quietly under-count with no signal. Currently passes on 0 rows
  because `fx_rates.csv` fully covers the booking date range - this test
  is insurance against a future data gap, not a fix for one found here.
- **`assert_currency_default_visibility.sql`** (WARN) - the null-currency
  default to PKR (documented above) is an accepted assumption, not a bug,
  so it's wired as a warning rather than an error: it "fails" on every
  build on purpose, surfacing the exact count of confirmed bookings
  affected (**26**) so a reviewer sees it in the build output instead of
  having to know to grep for it.
- **`assert_payment_reconciliation_within_tolerance.sql`** (WARN) -
  variances beyond a 1 PKR rounding tolerance are a reconciliation finding
  to investigate, not a build-blocking error, since the underlying payment
  data is what it is. Filters explicitly on `canonical_status = 'CONFIRMED'`
  (defense-in-depth - `rpt_payment_reconciliation` is already CONFIRMED-only
  upstream) and excludes `currency_was_defaulted` bookings, whose variance
  is really a mis-priced fare baseline already caught by the test above, not
  a settlement problem - see "Payment reconciliation FX basis" above.
  Bookings with no captured payment yet (`has_any_captured = false`) are
  also excluded, since "not yet paid" isn't a discrepancy. Currently warns
  on **7** confirmed, already-captured, non-defaulted-currency bookings -
  including the ~2x double-capture on `S86X7Y` noted above.

## What I'd do differently with more time / someone to ask

1. **Ask the LCC integration team where the null-`currency` rows come
   from**, and whether defaulting to PKR (26 of 713 confirmed bookings
   affected) is actually right. It's the single biggest revenue-affecting
   guess in this pipeline - every one of those bookings has its PKR revenue
   computed as if it were priced in PKR, when in fact we don't know what
   currency it was priced in. A wrong default here silently mis-states
   `net_revenue_pkr` for real bookings, with no error and no warning beyond
   the `assert_currency_default_visibility` WARN test. If there's a better
   signal available upstream (e.g. the currency the *carrier* normally
   bills in, or a field that got dropped before it reached this feed),
   that would replace the flat PKR default entirely.
2. **Ask whether the LCC millisecond-epoch rows (15 of 520 latest-state
   bookings) are a known bug in a specific upstream client version.** The
   current fix is a magnitude heuristic (`> 100000000000` implies
   milliseconds) that works on this data but has no confirmation from the
   source team - a legitimate far-future second-epoch value could in
   theory be misclassified, though none exist in this dataset.
3. **Confirm with the source teams whether GDS `segments` can ever coexist
   with the flat columns on the same record**, rather than inferring
   mutual exclusivity from the sample - it held for every row profiled,
   but was never confirmed as a guarantee.
4. **Confirm the cross-feed dedup rule directly with whoever owns the
   GDS/LCC integrations**, rather than inferring "same pnr + carrier's
   home feed wins" from the 6 duplicate bookings found by profiling - in
   particular, whether fare/flight details always agree between the two
   copies (spot-checked a few and they did) and whether `stg_airlines.feed`
   is the right tiebreaker versus, say, always preferring GDS as the
   system of record.
5. **Add a not_null test on `int_bookings_local_departure.origin_timezone`**
   (or equivalent) to actively catch any future `origin` airport missing
   from `stg_airports`, rather than relying on the current data happening
   to have full coverage (see "Known gaps" in `README.md`).
6. **Investigate the `S86X7Y` double-capture** (and any others the
   reconciliation report turns up) with whoever owns the payment gateway
   integration, rather than leaving it as a flagged-but-unexplained
   anomaly.
