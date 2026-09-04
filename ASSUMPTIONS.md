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

## What I'd do differently with more time / someone to ask

- Confirm with the source teams whether GDS `segments` can ever coexist with
  the flat columns on the same record, rather than inferring mutual
  exclusivity from the sample.
- Ask whether the LCC millisecond-epoch rows are a known bug in a specific
  upstream client version (would allow a more precise fix than a magnitude
  heuristic) and where the null-currency rows originate (would allow a more
  precise default than "assume PKR").
