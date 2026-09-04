-- Convert fare_amount to PKR at the rate for the date the booking was
-- made (booking_made_at), per the definition in README.md. Where no
-- fx_rates row exists for that (currency, date) pair, fare_amount_pkr is
-- left null and fx_rate_missing=true rather than silently dropping the
-- booking's revenue - downstream can decide how to treat it.

with bookings as (

    select * from {{ ref('int_bookings_local_departure') }}

),

fx as (

    select * from {{ ref('stg_fx_rates') }}

),

joined as (

    select
        bookings.*,
        fx.pkr_per_unit
    from bookings
    left join fx
        on fx.currency = bookings.fare_currency
        and fx.rate_date = cast(bookings.booking_made_at as date)

)

select
    *,
    fare_amount * pkr_per_unit  as fare_amount_pkr,
    pkr_per_unit is null        as fx_rate_missing
from joined
