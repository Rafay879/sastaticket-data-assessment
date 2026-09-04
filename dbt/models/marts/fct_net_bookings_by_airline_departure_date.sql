-- The deliverable: net confirmed bookings and net revenue (PKR), by
-- airline and local departure date. "Net" per README = latest known state
-- is CONFIRMED - PENDING (never ticketed) and CANCELLED are both excluded,
-- not just CANCELLED. See ASSUMPTIONS.md.

with bookings as (

    select * from {{ ref('int_bookings_fx_converted') }}
    where canonical_status = 'CONFIRMED'

)

select
    carrier                as airline_code,
    departure_date_local,
    count(*)                as net_confirmed_bookings,
    sum(pax_count)           as net_pax,
    sum(fare_amount_pkr)     as net_revenue_pkr
from bookings
group by carrier, departure_date_local
order by airline_code, departure_date_local
