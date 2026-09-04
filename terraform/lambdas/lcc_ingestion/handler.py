"""Lambda entrypoint for incremental LCC direct-connect bookings ingestion.

Production behavior:
    1. Reads the last-processed watermark (a UTC timestamp) for the
       `lcc_bookings` source from the DynamoDB watermarks table.
    2. Calls the upstream LCC direct-connect API, passing the watermark as
       a filter so only records created or updated since the last run are
       returned.
    3. Writes any new/changed records to the bronze S3 bucket as Parquet,
       partitioned under `lcc_bookings/created_date=YYYY-MM-DD/`.
    4. Advances the watermark in DynamoDB to the latest record timestamp
       seen - but only after the Parquet write succeeds, so a failed run
       can be retried without skipping or duplicating records.

Triggered on a schedule via the Step Functions state machine (see
../../modules/orchestration). Runs as an AWS Lambda function, Python 3.11.
"""

from typing import Any


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    # TODO: real implementation. See DEPLOYMENT.md section 1.
    return {"source": "lcc_bookings", "new_records": 0}
