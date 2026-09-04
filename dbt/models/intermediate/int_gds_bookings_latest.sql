-- Collapse the GDS append-only event log to one row per pnr: the latest
-- known state, plus booking_made_at computed across ALL of that pnr's
-- events (needed later for the FX rate date, which must reflect when the
-- booking was first made, not when it was last updated).

with gds as (

    select * from {{ ref('stg_gds_bookings') }}

),

status_map as (

    select raw_status, canonical_status
    from {{ ref('stg_status_codes') }}
    where feed = 'gds_bookings'

),

ranked as (

    select
        gds.*,
        min(record_created_utc) over (partition by pnr)                          as booking_made_at,
        row_number() over (partition by pnr order by record_created_utc desc)    as rn
    from gds

)

select
    ranked.pnr,
    ranked.booking_made_at,
    ranked.record_created_utc  as latest_event_at,
    status_map.canonical_status,
    ranked.carrier,
    ranked.pax_count,
    ranked.fare_base,
    ranked.fare_tax,
    ranked.fare_currency,
    ranked.flight_no,
    ranked.origin,
    ranked.destination,
    ranked.departure_local_raw,
    ranked.leg_count,
    'gds_bookings'              as source_feed
from ranked
left join status_map on ranked.status = status_map.raw_status
where ranked.rn = 1
