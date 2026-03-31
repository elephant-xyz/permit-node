# Prepare Permits Lambda

This Lambda function runs the `elephant-cli prepare-permits` command as the first step in the Step Function workflow, then splits the output CSV into smaller chunks and publishes each chunk to SQS.

## Functionality

- **Input**: SQS message containing S3 event with CSV file location
- **Process**: 
  1. Downloads the CSV file from S3
  2. Downloads portal.zip (either from environment variable `PORTAL_ZIP_S3_URI` or same directory as CSV)
  3. Runs `elephant-cli prepare-permits portal.zip --start <today> --end <today> --url-csv <csv-file>`
  4. Splits the output CSV into smaller chunks (configurable size)
  5. Uploads each chunk to S3 in an `outputs/` subdirectory
  6. Publishes SQS messages for each chunk to trigger downstream processing
- **Output**: Returns array of S3 URIs for CSV chunks, portal.zip used, and SQS message counts

## Environment Variables

- `PORTAL_ZIP_S3_URI` (optional): S3 URI pointing to portal.zip file. If not set, the lambda will look for portal.zip in the same directory as the input CSV file.
- `CHUNK_SQS_QUEUE_URL`: SQS Queue URL where chunk messages will be published
- `CSV_CHUNK_SIZE`: Number of rows per CSV chunk (default: 100, configurable via CloudFormation parameter)

## Configuration

- **Memory**: 512 MB
- **Timeout**: 300 seconds (5 minutes)
- **Architecture**: ARM64
- **Runtime**: Node.js (ESM)

## Dependencies

- `@aws-sdk/client-s3`: For S3 operations
- `@aws-sdk/client-sqs`: For SQS operations
- `@elephant-xyz/cli`: Uses permits branch from GitHub with latest prepare-permits command
- `csv-parse` and `csv-stringify`: For CSV manipulation

## Usage in Step Function

This lambda is now the first step (`PreparePermits`) in the Elephant Express workflow, replacing the previous first step. It processes CSV files that point to permit URLs and generates permit data for the specified date range (using today's date for both start and end).

## Output Format

The lambda returns:
```json
{
  "chunk_s3_uris": [
    "s3://bucket/path/to/outputs/filename_permits_YYYY-MM-DD_chunk_001.csv",
    "s3://bucket/path/to/outputs/filename_permits_YYYY-MM-DD_chunk_002.csv",
    "..."
  ],
  "portal_zip_s3_uri": "s3://bucket/path/to/portal.zip",
  "total_chunks": 5,
  "sqs_messages_sent": 5
}
```

This output is stored in the Step Function context under `$.permits` for use by subsequent steps.

## SQS Message Format

Each chunk generates an SQS message with the following structure:
```json
{
  "Records": [
    {
      "s3": {
        "bucket": {
          "name": "bucket-name"
        },
        "object": {
          "key": "path/to/outputs/filename_permits_YYYY-MM-DD_chunk_001.csv"
        }
      }
    }
  ]
}
```

With message attributes:
- `ChunkIndex`: Sequential number of this chunk (1, 2, 3, ...)
- `TotalChunks`: Total number of chunks created
- `OriginalFile`: S3 URI of this specific chunk

## Chunking Strategy

- Default chunk size: 100 rows per file
- Configurable via `CsvChunkSize` CloudFormation parameter
- Each chunk includes CSV headers
- Chunks are numbered sequentially with zero-padded names (001, 002, 003, etc.)
- Empty CSV files generate no chunks
