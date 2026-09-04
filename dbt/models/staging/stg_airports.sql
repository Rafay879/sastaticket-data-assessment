with source as (

    select * from {{ source('reference', 'airports') }}

),

renamed as (

    select
        iata_code,
        airport_name,
        city,
        country_code,
        timezone
    from source

)

select * from renamed
