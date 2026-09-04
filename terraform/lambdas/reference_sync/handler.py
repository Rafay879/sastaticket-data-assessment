"""Lambda entrypoint for reference data sync (airports, airlines, fx_rates,
status_codes).

Production behavior:
    1. Reads the last-processed watermark (a UTC timestamp) for the
       `reference_data` source from the DynamoDB watermarks table.
    2. Calls the upstream reference-data API, passing the watermark as a
       filter so only rows changed since the last run are returned (this
       feed is slow-moving, but the same incremental pattern is used for
       consistency with the other three ingestion Lambdas).
    3. Writes any new/changed rows to the bronze S3 bucket as Parquet,
       partitioned under `reference/created_date=YYYY-MM-DD/`.
    4. Advances the watermark in DynamoDB to the latest row timestamp seen
       - but only after the Parquet write succeeds, so a failed run can be
       retried without skipping or duplicating rows.

Triggered on a schedule via the Step Functions state machine (see
../../modules/orchestration). Runs as an AWS Lambda function, Python 3.11.
"""

from typing import Any


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    # TODO: real implementation. See DEPLOYMENT.md section 1.
    return {"source": "reference_data", "new_records": 0}
