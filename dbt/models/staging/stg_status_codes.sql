with source as (

    select * from {{ source('reference', 'status_codes') }}

),

renamed as (

    select
        feed,
        raw_status,
        canonical_status,
        notes
    from source

)

select * from renamed
