-- Union the two feeds into one shape, then apply cross-feed dedup: a
-- handful of real-world bookings on GDS-native carriers (e.g. PK, ED) leak
-- into the LCC direct-connect feed under the same booking reference - the
-- same booking captured twice by two different upstream systems, not two
-- different bookings that happen to collide. For any pnr that shows up in
-- both source_feeds, keep only the copy from that carrier's home feed
-- (per stg_airlines.feed) and drop the other, so the booking isn't
-- double-counted downstream.

with gds as (

    select
        pnr,
        booking_made_at,
        latest_event_at,
        canonical_status,
        carrier,
        pax_count,
        fare_base + fare_tax        as fare_amount,
        fare_currency,
        false                        as currency_was_defaulted,
        flight_no,
        origin,
        destination,
        departure_local_raw,
        cast(null as timestamptz)   as departure_utc_normalized,
        leg_count,
        source_feed
    from {{ ref('int_gds_bookings_latest') }}

),

lcc as (

    select
        pnr,
        booking_made_at,
        latest_event_at,
        canonical_status,
        carrier,
        pax_count,
        fare_amount,
        fare_currency,
        currency_was_defaulted,
        flight                       as flight_no,
        origin,
        destination,
        cast(null as timestamp)     as departure_local_raw,
        departure_utc_normalized,
        1                            as leg_count,
        source_feed
    from {{ ref('int_lcc_bookings_latest') }}

),

unioned as (

    select * from gds
    union all
    select * from lcc

),

airline_home_feed as (

    select airline_code, feed as home_feed
    from {{ ref('stg_airlines') }}

),

flagged as (

    select
        unioned.*,
        airline_home_feed.home_feed,
        count(*) over (partition by unioned.pnr)   as pnr_row_count
    from unioned
    left join airline_home_feed on unioned.carrier = airline_home_feed.airline_code

)

select
    pnr,
    booking_made_at,
    latest_event_at,
    canonical_status,
    carrier,
    pax_count,
    fare_amount,
    fare_currency,
    currency_was_defaulted,
    flight_no,
    origin,
    destination,
    departure_local_raw,
    departure_utc_normalized,
    leg_count,
    source_feed
from flagged
where pnr_row_count = 1
   or home_feed is null
   or source_feed = home_feed
