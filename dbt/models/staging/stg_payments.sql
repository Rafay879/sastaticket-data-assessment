-- WORKED EXAMPLE - provided so you do not spend time on plumbing.
-- Follow this pattern for the rest, or replace it with a better one.

with source as (

    select * from {{ source('raw', 'payments') }}

),

renamed as (

    select
        payment_id,
        booking_ref,
        cast(event_ts_utc as timestamptz)  as event_at_utc,
        cast(amount as decimal(18, 2))     as amount,
        currency,
        method,
        status                             as payment_status
    from source

)

select * from renamed
