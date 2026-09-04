-- GDS feed has two record shapes: older rows carry flat flight_no/origin/
-- destination/departure_local columns, newer rows carry a `segments` array
-- instead. Normalize both into one shape, using the lowest-`seq` segment
-- for multi-leg bookings. See ASSUMPTIONS.md.

with source as (

    select
        row_number() over ()   as _row_id,
        *
    from {{ source('raw', 'gds_bookings') }}

),

first_segment as (

    select
        _row_id,
        arg_min(s.flight_no, s.seq)        as seg_flight_no,
        arg_min(s.origin, s.seq)           as seg_origin,
        arg_min(s.destination, s.seq)      as seg_destination,
        arg_min(s.departure_local, s.seq)  as seg_departure_local,
        count(*)                           as seg_leg_count
    from source, unnest(segments) as t(s)
    group by _row_id

),

normalized as (

    select
        source.pnr,
        cast(source.record_created_utc as timestamptz)         as record_created_utc,
        source.status,
        source.carrier,
        source.pax_count,
        cast(source.fare.base as decimal(18, 2))                as fare_base,
        cast(source.fare.tax as decimal(18, 2))                 as fare_tax,
        source.fare.currency                                    as fare_currency,
        source.channel,
        coalesce(source.flight_no, first_segment.seg_flight_no)          as flight_no,
        coalesce(source.origin, first_segment.seg_origin)                as origin,
        coalesce(source.destination, first_segment.seg_destination)      as destination,
        cast(coalesce(source.departure_local, first_segment.seg_departure_local) as timestamp) as departure_local_raw,
        coalesce(first_segment.seg_leg_count, 1)                as leg_count
    from source
    left join first_segment using (_row_id)

)

select * from normalized
