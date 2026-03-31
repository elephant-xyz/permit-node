/**
 * Starter Lambda: Can be triggered by:
 * 1. Direct invocation with CSV data
 * 2. S3 events when CSV files are uploaded
 * 3. SQS messages with CSV data/paths
 * 
 * Handles CSV upload to S3 and starts the Step Function.
 */

import { SFNClient, StartSyncExecutionCommand } from "@aws-sdk/client-sfn";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";

/**
 * @typedef {Object} S3EventRecord
 * @property {{ name: string }} s3.bucket
 * @property {{ key: string }} s3.object
 */

/**
 * @typedef {Object} SqsEvent
 * @property {{ body: string }[]} Records
 */

const sfn = new SFNClient({});
const s3 = new S3Client({});

/**
 * Determine event type and format
 * @param {any} event 
 * @returns {{ isS3: boolean, isSQS: boolean, isDirect: boolean }}
 */
const getEventType = (event) => {
  if (event?.Records?.[0]?.eventSource === "aws:s3") {
    return { isS3: true, isSQS: false, isDirect: false };
  }
  if (event?.Records?.[0]?.eventSource === "aws:sqs") {
    return { isS3: false, isSQS: true, isDirect: false };
  }
  // Direct invocation with CSV data
  if (event?.csvContent || event?.csvBase64 || event?.csvPath) {
    return { isS3: false, isSQS: false, isDirect: true };
  }
  return { isS3: false, isSQS: false, isDirect: false };
};

/**
 * Upload CSV content to S3 and return S3 event format
 * @param {string} csvContent - CSV content as string
 * @param {string} filename - Desired filename
 * @returns {Promise<Object>} S3 event record format
 */
const uploadCsvToS3 = async (csvContent, filename) => {
  if (!process.env.INPUT_BUCKET_NAME) {
    throw new Error("INPUT_BUCKET_NAME environment variable is required");
  }
  
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const key = `${timestamp}-${filename}`;
  
  const putCommand = new PutObjectCommand({
    Bucket: process.env.INPUT_BUCKET_NAME,
    Key: key,
    Body: csvContent,
    ContentType: 'text/csv'
  });
  
  await s3.send(putCommand);
  
  // Return S3 event record format for consistency
  return {
    s3: {
      bucket: { name: process.env.INPUT_BUCKET_NAME },
      object: { key: key }
    }
  };
};

/**
 * @param {S3Event|SqsEvent} event
 * @returns {Promise<{status:string, executionArn?:string}>}
 */
export const handler = async (event) => {
  const logBase = { component: "starter", at: new Date().toISOString() };
  try {
    console.log(
      JSON.stringify({
        ...logBase,
        level: "info",
        msg: "received",
        eventSize: event?.Records?.length ?? 0,
      }),
    );
    if (!process.env.STATE_MACHINE_ARN) {
      throw new Error("STATE_MACHINE_ARN is required");
    }
    
    console.log(`Event is : ${JSON.stringify(event)}`);
    
    const { isS3, isSQS, isDirect } = getEventType(event);
    let message;
    
    if (isDirect) {
      // Handle direct invocation with CSV data
      console.log("Processing direct CSV input");
      
      let csvContent;
      let filename = event.filename || 'permits.csv';
      
      if (event.csvContent) {
        csvContent = event.csvContent;
      } else if (event.csvBase64) {
        csvContent = Buffer.from(event.csvBase64, 'base64').toString('utf-8');
      } else if (event.csvPath) {
        throw new Error("csvPath not yet supported - use csvContent or csvBase64");
      } else {
        throw new Error("Direct invocation requires csvContent, csvBase64, or csvPath");
      }
      
      // Upload CSV to S3 and create S3-style message
      message = await uploadCsvToS3(csvContent, filename);
      
    } else if (isS3) {
      // Handle S3 event directly
      console.log("Processing S3 event");
      if (!event || !Array.isArray(event.Records) || event.Records.length !== 1) {
        throw new Error("Expect exactly one record per invocation for S3 events");
      }
      message = event.Records[0];
      
    } else if (isSQS) {
      // Handle SQS event (parse the body)
      console.log("Processing SQS event");
      if (!event || !Array.isArray(event.Records) || event.Records.length !== 1) {
        throw new Error("Expect exactly one record per invocation for SQS events");
      }
      const bodyRaw = event.Records[0].body;
      message = JSON.parse(bodyRaw);
      
    } else {
      throw new Error("Unknown event type - expected S3 event, SQS event, or direct CSV input");
    }
    
    // Start the Express workflow synchronously
    const cmd = new StartSyncExecutionCommand({
      stateMachineArn: process.env.STATE_MACHINE_ARN,
      input: JSON.stringify({ message }),
    });
    const resp = await sfn.send(cmd);
    console.log(
      JSON.stringify({
        ...logBase,
        level: "info",
        msg: "completed",
        executionArn: resp.executionArn,
        status: resp.status,
        eventType: isS3 ? "S3" : "SQS",
      }),
    );
    // Always return success to acknowledge message processing
    // The state machine handles requeuing on failures
    return {
      status: "ok",
      executionArn: resp.executionArn,
      workflowStatus: resp.status,
    };
  } catch (err) {
    console.error(
      JSON.stringify({
        ...logBase,
        level: "error",
        msg: "failed",
        error: String(err),
      }),
    );
    // Always return success to SQS even on errors
    // SQS message should be acknowledged to prevent infinite retries
    return { status: "error", error: String(err) };
  }
};
