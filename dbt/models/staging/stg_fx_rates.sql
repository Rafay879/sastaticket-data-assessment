with source as (

    select * from {{ source('reference', 'fx_rates') }}

),

renamed as (

    select
        cast(rate_date as date)              as rate_date,
        currency,
        cast(pkr_per_unit as decimal(18, 6)) as pkr_per_unit
    from source

)

select * from renamed
