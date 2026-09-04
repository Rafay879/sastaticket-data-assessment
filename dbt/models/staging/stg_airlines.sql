with source as (

    select * from {{ source('reference', 'airlines') }}

),

renamed as (

    select
        airline_code,
        airline_name,
        feed
    from source

)

select * from renamed
