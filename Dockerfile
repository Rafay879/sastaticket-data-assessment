FROM python:3.11-slim

RUN pip install --no-cache-dir dbt-duckdb==1.11.0 dbt-core==1.12.3

WORKDIR /app
COPY dbt/ dbt/
COPY data/ data/
COPY reference/ reference/

WORKDIR /app/dbt

# sources.yml external_location paths (e.g. ../data/raw/*.csv) are relative to the dbt project dir, so dbt must run from /app/dbt
CMD ["dbt", "build"]
