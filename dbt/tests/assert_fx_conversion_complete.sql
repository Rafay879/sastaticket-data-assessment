-- A confirmed booking with no matching fx_rates row would have its
-- revenue silently dropped from sum(fare_amount_pkr) - null doesn't error,
-- it just vanishes from the total. fx_rate_missing exists specifically so
-- that case can be caught instead of quietly under-counting revenue. This
-- test currently passes on 0 rows because fx_rates.csv fully covers the
-- observed booking date range (see ASSUMPTIONS.md) - it's a safety net for
-- future data, not a fix for a problem found in this dataset.

select *
from {{ ref('int_bookings_fx_converted') }}
where canonical_status = 'CONFIRMED'
  and fx_rate_missing
