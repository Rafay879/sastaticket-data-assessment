-- LCC feed. currency and the unit of departure_utc (seconds vs milliseconds,
-- both observed) are left as-is here and handled in the intermediate layer.
-- See ASSUMPTIONS.md.

with source as (

    select * from {{ source('raw', 'lcc_bookings') }}

),

renamed as (

    select
        booking_reference,
        to_timestamp(created_ts)         as created_ts,
        state,
        airline_code,
        flight,
        route,
        cast(departure_utc as bigint)    as departure_utc_raw,
        passengers,
        cast(amount as decimal(18, 2))   as amount,
        src,
        currency
    from source

)

select * from renamed
