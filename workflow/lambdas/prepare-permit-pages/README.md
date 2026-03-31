# Prepare Permit Pages Lambda

This Lambda function runs the `elephant-cli prepare-permit-pages` command on individual CSV chunks as part of the Express Step Function workflow.

## Functionality

- **Input**: SQS message containing S3 event with CSV chunk location
- **Process**: 
  1. Downloads the CSV chunk from S3
  2. Creates a ZIP file containing the CSV chunk
  3. Runs `elephant-cli prepare-permit-pages <csv-zip> --output <output-zip>`
  4. Uploads the result ZIP to S3 in a `results/` subdirectory
- **Output**: Returns S3 URI for the generated ZIP file and processing metadata

## Configuration

- **Memory**: 512 MB
- **Timeout**: 300 seconds (5 minutes)
- **Architecture**: ARM64
- **Runtime**: Node.js (ESM)

## Dependencies

- `@aws-sdk/client-s3`: For S3 operations
- `@elephant-xyz/cli`: Uses permits branch from GitHub with latest prepare-permit-pages command
- `adm-zip`: For creating ZIP files

## Usage in Step Function

This lambda is triggered by the PermitPagesExpress Step Function, which processes individual CSV chunks sent to the ChunkProcessingSqsQueue. Each chunk is processed independently and in parallel.

## Input Format

The lambda expects SQS messages with the following structure:
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

With optional message attributes:
- `ChunkIndex`: Sequential number of this chunk
- `TotalChunks`: Total number of chunks being processed
- `OriginalFile`: S3 URI of this specific chunk

## Output Format

The lambda returns:
```json
{
  "output_s3_uri": "s3://bucket/path/to/results/filename_permits_YYYY-MM-DD_pages_chunk_001.zip",
  "input_csv_s3_uri": "s3://bucket/path/to/outputs/filename_permits_YYYY-MM-DD_chunk_001.csv",
  "processing_time_ms": 45000
}
```

## File Processing

- **Input**: CSV chunk file downloaded from S3
- **Intermediate**: CSV wrapped in ZIP format for elephant-cli
- **Output**: ZIP file containing processed permit pages
- **Naming**: `_chunk_XXX.csv` becomes `_pages_chunk_XXX.zip`
- **Location**: Results stored in `results/` instead of `outputs/` directory

## Error Handling

- Retries on Lambda service exceptions (up to 3 attempts)
- Proper error propagation for SQS Dead Letter Queue handling
- Detailed logging for debugging and monitoring
- Cleanup of temporary files in all scenarios

## Parallel Processing

- Each CSV chunk is processed independently
- Supports high concurrency (up to 50 concurrent executions)
- No dependencies between chunks
- Ideal for large datasets split into manageable pieces
