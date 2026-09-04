{{ config(severity = 'warn') }}

-- WARN, not error: a billed-vs-settled variance is a reconciliation
-- finding to investigate (e.g. the double-capture pattern found on booking
-- S86X7Y during development - see ASSUMPTIONS.md), not a build-blocking
-- data error - the underlying source data is what it is. Rounding noise
-- up to 1 PKR is tolerated. Bookings with no captured payment at all
-- (has_any_captured=false) are excluded - they simply haven't settled yet,
-- which isn't a discrepancy.
--
-- canonical_status = 'CONFIRMED' is explicit here even though
-- rpt_payment_reconciliation is already CONFIRMED-only upstream - checked
-- during development whether cancelled-with-refund bookings might be
-- driving these warnings; they weren't (all 9 were already CONFIRMED), but
-- the explicit filter documents the intent and guards against a future
-- change to the model's scope.
--
-- currency_was_defaulted bookings are excluded from THIS test: 2 of the
-- original 9 warnings (WTZB55, 0LL2P5) turned out to have a mis-priced
-- fare_amount_pkr baseline, not a settlement problem - their fare currency
-- was defaulted to PKR (see assert_currency_default_visibility.sql), but
-- the actual gateway payment came through in AED, so difference_pkr was
-- comparing a wrongly-denominated fare against a correctly-converted
-- settlement. That's already surfaced by the currency-default test;
-- counting it again here would double-report the same root cause under a
-- misleading "settlement variance" label.

select *
from {{ ref('rpt_payment_reconciliation') }}
where abs(difference_pkr) > 1
  and has_any_captured
  and canonical_status = 'CONFIRMED'
  and not currency_was_defaulted
