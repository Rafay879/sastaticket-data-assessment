-- Same collapse-to-latest pattern as int_gds_bookings_latest, plus the two
-- fixes flagged in ASSUMPTIONS.md as deferred from staging: the mixed
-- seconds/milliseconds departure_utc unit, and the null currency default.
-- The null-ness of currency is preserved in currency_was_defaulted rather
-- than silently overwritten, so it can still be tested/audited downstream.

with lcc as (

    select * from {{ ref('stg_lcc_bookings') }}

),

status_map as (

    select raw_status, canonical_status
    from {{ ref('stg_status_codes') }}
    where feed = 'lcc_bookings'

),

fixed as (

    select
        lcc.*,
        case
            when departure_utc_raw > 100000000000 then departure_utc_raw // 1000
            else departure_utc_raw
        end as departure_epoch_seconds
    from lcc

),

ranked as (

    select
        fixed.*,
        min(created_ts) over (partition by booking_reference)                          as booking_made_at,
        row_number() over (partition by booking_reference order by created_ts desc)    as rn
    from fixed

)

select
    ranked.booking_reference                       as pnr,
    ranked.booking_made_at,
    ranked.created_ts                              as latest_event_at,
    status_map.canonical_status,
    ranked.airline_code                            as carrier,
    ranked.passengers                              as pax_count,
    ranked.amount                                  as fare_amount,
    coalesce(ranked.currency, 'PKR')                as fare_currency,
    ranked.currency is null                         as currency_was_defaulted,
    ranked.flight,
    split_part(ranked.route, '-', 1)                as origin,
    split_part(ranked.route, '-', 2)                as destination,
    to_timestamp(ranked.departure_epoch_seconds)    as departure_utc_normalized,
    'lcc_bookings'                                  as source_feed
from ranked
left join status_map on ranked.state = status_map.raw_status
where ranked.rn = 1
