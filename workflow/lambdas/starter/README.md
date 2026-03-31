# WorkflowStarterFunction

This Lambda function can be triggered in three ways to start the permit processing workflow:

## 1. Direct Invocation with CSV Data (Recommended)

The simplest way to start the workflow is by invoking the Lambda directly with CSV data:

### Using AWS CLI:
```bash
# Option A: Inline CSV content
aws lambda invoke \
  --function-name WorkflowStarterFunction \
  --payload '{
    "csvContent": "header1,header2\nvalue1,value2\nvalue3,value4",
    "filename": "my-permits.csv"
  }' \
  response.json

# Option B: Base64 encoded CSV
aws lambda invoke \
  --function-name WorkflowStarterFunction \
  --payload '{
    "csvBase64": "aGVhZGVyMSxoZWFkZXIyCnZhbHVlMSx2YWx1ZTIKdmFsdWUzLHZhbHVlNA==",
    "filename": "my-permits.csv"
  }' \
  response.json
```

### Payload Format:
```json
{
  "csvContent": "string",     // Raw CSV content (Option A)
  "csvBase64": "string",      // Base64 encoded CSV (Option B)  
  "filename": "string"        // Optional: filename (defaults to "permits.csv")
}
```

## 2. S3 Event Trigger

When CSV files are uploaded to the InputBucket, the workflow starts automatically:

```bash
# Upload CSV file to trigger workflow
aws s3 cp my-permits.csv s3://your-input-bucket/
```

**Requirements:**
- S3 bucket notifications must be configured (see `scripts/configure-s3-notifications.sh`)
- File must have `.csv` extension

## 3. SQS Message Trigger

Send SQS message with S3 event data:

```bash
aws sqs send-message \
  --queue-url YOUR_QUEUE_URL \
  --message-body '{
    "s3": {
      "bucket": {"name": "your-bucket"},
      "object": {"key": "permits.csv"}
    }
  }'
```

## Environment Variables

- `STATE_MACHINE_ARN`: ARN of the Step Function to start
- `INPUT_BUCKET_NAME`: S3 bucket where CSVs are uploaded

## Function Behavior

1. **Receives** CSV data (direct, S3 event, or SQS)
2. **Uploads** CSV to InputBucket (if direct invocation)
3. **Starts** the permit processing Step Function
4. **Returns** execution details

## Response Format

```json
{
  "status": "ok",
  "executionArn": "arn:aws:states:...",
  "workflowStatus": "SUCCEEDED"
}
```

## Quick Start

The easiest way to test the workflow:

```bash
# 1. Deploy infrastructure
./scripts/deploy-infra.sh

# 2. Test with sample CSV
aws lambda invoke \
  --function-name WorkflowStarterFunction \
  --payload '{"csvContent": "permit_id,address\n1,123 Main St\n2,456 Oak Ave", "filename": "test.csv"}' \
  response.json

# 3. Check response
cat response.json
```

This approach eliminates the need for S3 bucket notifications and makes testing much simpler!