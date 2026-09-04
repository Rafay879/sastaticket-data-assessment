{{ config(severity = 'warn') }}

-- WARN, not error: a billed-vs-settled variance is a reconciliation
-- finding to investigate (e.g. the ~2x double-capture found on booking
-- S86X7Y during development - see ASSUMPTIONS.md), not a build-blocking
-- data error - the underlying source data is what it is. Rounding noise
-- up to 1 PKR is tolerated. Bookings with no captured payment at all
-- (has_any_captured=false) are excluded - they simply haven't settled yet,
-- which isn't a discrepancy.

select *
from {{ ref('rpt_payment_reconciliation') }}
where abs(difference_pkr) > 1
  and has_any_captured
