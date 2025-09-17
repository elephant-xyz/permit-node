## Elephant Express: Simple Usage

This repo deploys an AWS Step Functions (Express) workflow with SQS and Lambda. Follow these steps to get it running quickly.

### 1) Set environment variables

The oracle node supports two authentication modes:

#### Option A: Traditional Mode (using API credentials)

Export these environment variables before deploying:

```bash
# Required for traditional mode
export ELEPHANT_DOMAIN=...
export ELEPHANT_API_KEY=...
export ELEPHANT_ORACLE_KEY_ID=...
export ELEPHANT_FROM_ADDRESS=...
export ELEPHANT_RPC_URL=...
export ELEPHANT_PINATA_JWT=...

# Optional (deployment)
export STACK_NAME=elephant-permit-node
export WORKFLOW_QUEUE_NAME=permit-workflow-queue
export WORKFLOW_STARTER_RESERVED_CONCURRENCY=100
export WORKFLOW_STATE_MACHINE_NAME=ElephantExpressWorkflow

# Optional (AWS CLI)
export AWS_PROFILE=your-profile
export AWS_REGION=your-region

# Optional (Prepare function flags - only set to 'true' if needed)
export ELEPHANT_PREPARE_USE_BROWSER=false  # Force browser mode
export ELEPHANT_PREPARE_NO_FAST=false      # Disable fast mode
export ELEPHANT_PREPARE_NO_CONTINUE=false  # Disable continue mode

# Optional (Updater schedule - only set if you want to change from default)
export UPDATER_SCHEDULE_RATE="1 minute"    # How often updater runs (default: "1 minute")
# For sub-minute intervals, use cron expressions:
# export UPDATER_SCHEDULE_RATE="cron(*/1 * * * ? *)"  # Every minute
# export UPDATER_SCHEDULE_RATE="cron(0/30 * * * ? *)" # Every 30 seconds (at :00 and :30)
```

#### Option B: Keystore Mode (using encrypted private key)

For non-institutional oracles, you can use your own wallter as a keystore file (encrypted private key) instead of API credentials. The keystore file follows the [EIP-2335 standard](https://eips.ethereum.org/EIPS/eip-2335) for BLS12-381 key encryption.

To create a keystore file, see the [Elephant CLI documentation on encrypted JSON keystores](https://github.com/elephant-xyz/elephant-cli?tab=readme-ov-file#encrypted-json-keystore)

```bash
# Required for keystore mode
export ELEPHANT_KEYSTORE_FILE=/path/to/your/keystore.json  # Path to your keystore JSON file
export ELEPHANT_KEYSTORE_PASSWORD=your-keystore-password   # Password to decrypt the keystore
export ELEPHANT_RPC_URL=...                                # RPC URL for blockchain submission
export ELEPHANT_PINATA_JWT=...                             # Pinata JWT for uploads

# Optional (deployment)
export STACK_NAME=elephant-permit-node
export WORKFLOW_QUEUE_NAME=permit-workflow-queue
export WORKFLOW_STARTER_RESERVED_CONCURRENCY=100
export WORKFLOW_STATE_MACHINE_NAME=ElephantExpressWorkflow

# Optional (AWS CLI)
export AWS_PROFILE=your-profile
export AWS_REGION=your-region

# Optional (Prepare function flags - only set to 'true' if needed)
export ELEPHANT_PREPARE_USE_BROWSER=false  # Force browser mode
export ELEPHANT_PREPARE_NO_FAST=false      # Disable fast mode
export ELEPHANT_PREPARE_NO_CONTINUE=false  # Disable continue mode
```

**Important Notes for Keystore Mode:**
- The keystore file must exist at the specified path
- The password must be correct to decrypt the keystore
- The keystore file will be securely uploaded to S3 during deployment
- When using keystore mode, you don't need to provide: `ELEPHANT_DOMAIN`, `ELEPHANT_API_KEY`, `ELEPHANT_ORACLE_KEY_ID`, or `ELEPHANT_FROM_ADDRESS`
- To create a keystore file, see the [Elephant CLI documentation on encrypted JSON keystores](https://github.com/elephant-xyz/elephant-cli?tab=readme-ov-file#encrypted-json-keystore)

Put your transform files under `transform/` (if applicable).

### 2) Deploy infrastructure

```bash
./scripts/deploy-infra.sh
```

This creates the VPC, S3 buckets, SQS queues, Lambdas, and the Express Step Functions state machine.

### Configure Prepare Function Behavior

The `DownloaderFunction` uses the `prepare` command from `@elephant-xyz/cli` to fetch and process data. You can control its behavior using environment variables that map to CLI flags:

| Environment Variable           | Default | CLI Flag        | Description                     |
| ------------------------------ | ------- | --------------- | ------------------------------- |
| `ELEPHANT_PREPARE_USE_BROWSER` | `false` | `--use-browser` | Force browser mode for fetching |
| `ELEPHANT_PREPARE_NO_FAST`     | `false` | `--no-fast`     | Disable fast mode               |
| `ELEPHANT_PREPARE_NO_CONTINUE` | `false` | `--no-continue` | Disable continue mode           |
| `UPDATER_SCHEDULE_RATE`        | `"1 minute"` | N/A        | Updater frequency (e.g., "5 minutes", "cron(*/1 * * * ? *)") |

**Deploy with custom prepare flags:**

```bash
# Deploy with browser mode enabled
sam deploy --parameter-overrides \
  ElephantPrepareUseBrowser="true" \
  ElephantPrepareNoFast="false" \
  ElephantPrepareNoContinue="false"


# Or set as environment variables before deploy-infra.sh
export ELEPHANT_PREPARE_USE_BROWSER=true
export ELEPHANT_PREPARE_NO_FAST=true
export UPDATER_SCHEDULE_RATE="2 minutes"
./scripts/deploy-infra.sh
```

**View prepare function logs:**

The Lambda logs will show exactly which options are being used:

```
Building prepare options...
Event browser setting: undefined (using: true)
Checking environment variables for prepare flags:
✓ ELEPHANT_PREPARE_USE_BROWSER='true' → adding useBrowser: true
✗ ELEPHANT_PREPARE_NO_FAST='false' → not adding noFast flag
✗ ELEPHANT_PREPARE_NO_CONTINUE='false' → not adding noContinue flag
Calling prepare() with these options...
```

### Keystore Mode Details

The keystore mode provides a secure way to manage private keys for blockchain submissions using the industry-standard [EIP-2335](https://eips.ethereum.org/EIPS/eip-2335) encryption format.

**How it works:**
1. The deployment script validates that the keystore file exists and the password is provided
2. The keystore file is securely uploaded to S3 in the environment bucket under `keystores/` prefix
3. Lambda functions are configured with the S3 location and password as encrypted environment variables
4. During execution, the submit Lambda downloads the keys tore from S3 and uses it for blockchain submissions

**Creating a Keystore File:**
You can create a keystore file using the Elephant CLI tool. For detailed instructions, refer to the [Elephant CLI Encrypted JSON Keystore documentation](https://github.com/elephant-xyz/elephant-cli?tab=readme-ov-file#encrypted-json-keystore).

**Security considerations:**
- The keystore uses EIP-2335 standard encryption (PBKDF2 with SHA-256 for key derivation, AES-128-CTR for encryption)
- The keystore file is stored encrypted in S3 with versioning enabled for audit trails
- The password is stored as an encrypted environment variable in Lambda
- Lambda functions have minimal S3 permissions (read-only access to keystores only)
- The keystore is only downloaded to Lambda's temporary storage during execution and is immediately cleaned up after use

### Update transform scripts

To update your transforms:

- Place or update files under `transform/scripts/`.
- Redeploy to package and upload the latest transforms:

```bash
./scripts/deploy-infra.sh
```

### 3) Start the workflow

Use your input S3 bucket name:

```bash
./scripts/start-step-function.sh <your-bucket-name>
```

Available bucket names as of now:

- elephant-input-breavard-county
- elephant-input-broward-county
- elephant-input-charlotte-county
- elephant-input-duval-county
- elephant-input-hillsborough-county
- elephant-input-lake-county
- elephant-input-lee-county
- elephant-input-leon-county
- elephant-input-manatee-county
- elephant-input-palm-beach-county
- elephant-input-pinellas-county
- elephant-input-polk-county
- elephant-input-santa-county

### 4) Pause your Airflow DAG

If you also run an Airflow/MWAA pipeline for the same data, open the Airflow UI and toggle the DAG off (pause) to avoid duplicate processing.

### Monitor the workflow

- Step Functions: open AWS Console → Step Functions → State machines. The Express workflow name contains "ElephantExpressWorkflow". View current and recent executions.
- Logs: CloudWatch Logs group `/aws/vendedlogs/states/ElephantExpressWorkflow` contains execution logs for the Express workflow.

Helpful docs:

- Processing input and output in Step Functions: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-input-output-filtering.html
- Monitoring Step Functions: https://docs.aws.amazon.com/step-functions/latest/dg/proddash.html

### Control concurrency

Throughput is governed by the SQS → Lambda trigger on `WorkflowStarterFunction`:

- Batch size: number of SQS messages per Lambda invoke. Keep it small (often 1) to process one job per execution.
- Reserved concurrency on the Lambda: caps how many executions run in parallel.

Use the AWS Console → Lambda → `WorkflowStarterFunction` → Configuration → Triggers (SQS) to adjust Batch size, and Configuration → Concurrency to set reserved concurrency.

Docs:

- Using AWS Lambda with Amazon SQS: https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html
- Managing Lambda function concurrency: https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html

### Inspect failures

- Step Functions Console: select your Express state machine → Executions → filter by Failed → open an execution to see the error and the failed state.
- CloudWatch Logs: from the execution view, follow the log link to see state logs. You can also open the Lambda’s log groups for detailed stack traces.

Docs:

- View Step Functions execution history and errors: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-states.html#concepts-states-errors
- CloudWatch Logs for Step Functions: https://docs.aws.amazon.com/step-functions/latest/dg/cloudwatch-log-standard.html

That’s it — set env vars, deploy, start, monitor, and tune concurrency.

```

```
