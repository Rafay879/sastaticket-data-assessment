{{ config(severity = 'warn') }}

-- WARN, not error: defaulting a null LCC currency to PKR is an accepted
-- judgement call (see ASSUMPTIONS.md), not a data-quality failure that
-- should block a build. This test intentionally "fails" (warns) on every
-- run so the count of defaulted, confirmed bookings is visible in every
-- `dbt build` output, rather than something a reviewer has to know to grep
-- for.

select *
from {{ ref('int_bookings_fx_converted') }}
where currency_was_defaulted
  and canonical_status = 'CONFIRMED'
