-- Departure date must be the local calendar date at the origin airport.
-- GDS's departure_local_raw is already wall-clock local time - no
-- conversion, just take the date. LCC's departure_utc_normalized is UTC,
-- so it's converted to the origin airport's timezone (via icu) first.

with bookings as (

    select * from {{ ref('int_bookings_unioned') }}

),

airports as (

    select iata_code, timezone from {{ ref('stg_airports') }}

),

joined as (

    select
        bookings.*,
        airports.timezone as origin_timezone
    from bookings
    left join airports on bookings.origin = airports.iata_code

)

select
    *,
    case
        when source_feed = 'gds_bookings'
            then cast(departure_local_raw as date)
        when source_feed = 'lcc_bookings'
            then cast(departure_utc_normalized at time zone origin_timezone as date)
    end as departure_date_local
from joined
