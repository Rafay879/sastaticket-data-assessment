-- README: "A booking that was later cancelled does not count." For every
-- (airline_code, departure_date_local) slice that contains at least one
-- CANCELLED booking, independently recompute the CONFIRMED-only count
-- straight from int_bookings_fx_converted and compare it to what actually
-- landed in the mart. Any mismatch means a cancelled booking's count/
-- revenue leaked through - the exact bug the README warns about.

with cancelled_slices as (

    select distinct
        carrier                as airline_code,
        departure_date_local
    from {{ ref('int_bookings_fx_converted') }}
    where canonical_status = 'CANCELLED'

),

confirmed_recount as (

    select
        carrier                as airline_code,
        departure_date_local,
        count(*)                as expected_net_confirmed_bookings
    from {{ ref('int_bookings_fx_converted') }}
    where canonical_status = 'CONFIRMED'
    group by carrier, departure_date_local

)

select
    fct.airline_code,
    fct.departure_date_local,
    fct.net_confirmed_bookings,
    coalesce(confirmed_recount.expected_net_confirmed_bookings, 0) as expected_net_confirmed_bookings
from cancelled_slices
join {{ ref('fct_net_bookings_by_airline_departure_date') }} fct
    on fct.airline_code = cancelled_slices.airline_code
    and fct.departure_date_local = cancelled_slices.departure_date_local
left join confirmed_recount
    on confirmed_recount.airline_code = fct.airline_code
    and confirmed_recount.departure_date_local = fct.departure_date_local
where fct.net_confirmed_bookings != coalesce(confirmed_recount.expected_net_confirmed_bookings, 0)
