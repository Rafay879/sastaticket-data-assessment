{% test composite_unique(model, combination_of_columns) %}

with validation as (

    select
        {{ combination_of_columns | join(', ') }},
        count(*) as num_rows
    from {{ model }}
    group by {{ combination_of_columns | join(', ') }}

),

validation_errors as (

    select * from validation
    where num_rows > 1

)

select * from validation_errors

{% endtest %}
