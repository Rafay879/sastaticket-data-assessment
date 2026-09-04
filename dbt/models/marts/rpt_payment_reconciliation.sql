-- QC report, not part of the required metric: for each confirmed,
-- FX-convertible booking, compare billed fare (fare_amount_pkr) against
-- what was actually settled through the payment gateway (captured minus
-- refunded). FAILED payments are ignored entirely - they never moved
-- money. Both sides are converted using the FX rate for the booking's
-- booking_made_at date (not the payment date): this is a "billed vs
-- collected" data-quality check, not P&L, so both amounts need to sit on
-- the same FX basis or FX drift between booking and payment dates would
-- show up as a fake variance. A real revenue reconciliation would use
-- payment-date FX for cash actually received.

with bookings as (

    select
        pnr             as booking_ref,
        source_feed,
        booking_made_at,
        fare_currency,
        fare_amount_pkr
    from {{ ref('int_bookings_fx_converted') }}
    where canonical_status = 'CONFIRMED'
      and fare_amount_pkr is not null

),

payments as (

    select
        booking_ref,
        max(currency)                                                     as payment_currency,
        sum(case when payment_status = 'CAPTURED' then amount else 0 end) as captured_amount_native,
        sum(case when payment_status = 'REFUNDED' then amount else 0 end) as refunded_amount_native
    from {{ ref('stg_payments') }}
    group by booking_ref

),

settled as (

    select
        bookings.booking_ref,
        bookings.source_feed,
        bookings.fare_amount_pkr,
        bookings.booking_made_at,
        -- falls back to the booking's own currency when a booking has no
        -- payment rows at all, so the fx join below still resolves
        coalesce(payments.payment_currency, bookings.fare_currency)  as settlement_currency,
        coalesce(payments.captured_amount_native, 0)                 as captured_amount_native,
        coalesce(payments.captured_amount_native, 0)
            - coalesce(payments.refunded_amount_native, 0)            as net_settled_native
    from bookings
    left join payments on bookings.booking_ref = payments.booking_ref

),

converted as (

    select
        settled.*,
        fx.pkr_per_unit
    from settled
    left join {{ ref('stg_fx_rates') }} fx
        on fx.currency = settled.settlement_currency
        and fx.rate_date = cast(settled.booking_made_at as date)

)

select
    booking_ref,
    source_feed,
    fare_amount_pkr,
    net_settled_native * pkr_per_unit                      as net_settled_pkr,
    (net_settled_native * pkr_per_unit) - fare_amount_pkr  as difference_pkr,
    captured_amount_native > 0                              as has_any_captured
from converted
