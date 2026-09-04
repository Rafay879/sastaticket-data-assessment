-- Payment gateway events with no matching booking in either feed (after
-- dedup). Not used by the core metric, but worth surfacing separately
-- rather than silently dropping via an inner join elsewhere.

with payments as (

    select * from {{ ref('stg_payments') }}

),

bookings as (

    select distinct pnr from {{ ref('int_bookings_unioned') }}

)

select payments.*
from payments
left join bookings on payments.booking_ref = bookings.pnr
where bookings.pnr is null
