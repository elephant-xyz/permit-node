import {
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { promises as fs } from "fs";
import path from "path";
import os from "os";
import { parse } from "csv-parse/sync";
import { stringify } from "csv-stringify/sync";
import AdmZip from "adm-zip";
import { preparePermits } from "@elephant-xyz/cli/lib";

/**
 * @typedef {Object} PreparePermitsOutput
 * @property {string[]} chunk_s3_uris - Array of S3 URIs for the CSV chunks
 * @property {string} portal_zip_s3_uri - S3 URI of the portal.zip file used
 * @property {number} total_chunks - Total number of CSV chunks created
 * @property {number} sqs_messages_sent - Number of SQS messages sent
 */

const s3 = new S3Client({});
const sqs = new SQSClient({});

/**
 * Splits an Amazon S3 URI into its bucket name and object key.
 *
 * @param {string} s3Uri - A valid S3 URI in the format `s3://<bucket>/<key>`.
 * @returns {{ bucket: string, key: string }} An object containing bucket name and key.
 * @throws {Error} If the input is not a valid S3 URI.
 */
const splitS3Uri = (s3Uri) => {
  const RE_S3PATH = /^s3:\/\/([^/]+)\/(.*)$/i;
  const match = RE_S3PATH.exec(s3Uri);

  if (!match) {
    throw new Error("S3 path should be like: s3://bucket/object");
  }

  const [, bucket, key] = match;
  return { bucket, key };
};

/**
 * Get today's date formatted as MM/dd/yyyy
 * @returns {string} Today's date in MM/dd/yyyy format
 */
const getTodaysDate = () => {
  const today = new Date();
  const month = String(today.getMonth() + 1).padStart(2, '0');
  const day = String(today.getDate()).padStart(2, '0');
  const year = today.getFullYear();
  return `${month}/${day}/${year}`;
};


/**
 * Split CSV data into chunks and upload each chunk to S3
 * @param {string} csvFilePath - Path to the CSV file to split
 * @param {string} bucket - S3 bucket name
 * @param {string} baseKey - Base S3 key for the chunks
 * @param {number} chunkSize - Number of rows per chunk (default: 100)
 * @returns {Promise<string[]>} Array of S3 URIs for the uploaded chunks
 */
const splitAndUploadCsv = async (csvFilePath, bucket, baseKey, chunkSize = 100) => {
  console.log(`📊 Splitting CSV file: ${csvFilePath} into chunks of ${chunkSize} rows`);
  
  // Read and parse the CSV file
  const csvContent = await fs.readFile(csvFilePath, 'utf8');
  const records = parse(csvContent, {
    columns: true,
    skip_empty_lines: true,
    trim: true
  });
  
  console.log(`📋 Total records found: ${records.length}`);
  
  if (records.length === 0) {
    console.log("⚠️ No records found in CSV file");
    return [];
  }
  
  // Get column headers
  const headers = Object.keys(records[0]);
  const chunkS3Uris = [];
  
  // Split into chunks
  for (let i = 0; i < records.length; i += chunkSize) {
    const chunk = records.slice(i, i + chunkSize);
    const chunkNumber = Math.floor(i / chunkSize) + 1;
    const totalChunks = Math.ceil(records.length / chunkSize);
    
    console.log(`📦 Processing chunk ${chunkNumber}/${totalChunks} (${chunk.length} rows)`);
    
    // Convert chunk back to CSV
    const chunkCsv = stringify(chunk, {
      header: true,
      columns: headers
    });
    
    // Upload chunk to S3
    const chunkKey = `${baseKey}_chunk_${chunkNumber.toString().padStart(3, '0')}.csv`;
    await s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: chunkKey,
        Body: Buffer.from(chunkCsv, 'utf8'),
        ContentType: 'text/csv'
      })
    );
    
    const chunkS3Uri = `s3://${bucket}/${chunkKey}`;
    chunkS3Uris.push(chunkS3Uri);
    console.log(`✅ Uploaded chunk ${chunkNumber}: ${chunkS3Uri}`);
  }
  
  console.log(`🎯 Successfully created ${chunkS3Uris.length} CSV chunks`);
  return chunkS3Uris;
};

/**
 * Send SQS messages for each CSV chunk
 * @param {string[]} chunkS3Uris - Array of S3 URIs for CSV chunks
 * @param {string} queueUrl - SQS queue URL
 * @returns {Promise<number>} Number of messages sent
 */
const publishChunksToSqs = async (chunkS3Uris, queueUrl) => {
  console.log(`📨 Publishing ${chunkS3Uris.length} messages to SQS: ${queueUrl}`);
  
  let messagesSent = 0;
  
  for (const [index, chunkS3Uri] of chunkS3Uris.entries()) {
    const { bucket, key } = splitS3Uri(chunkS3Uri);
    
    // Create S3 event-like message structure
    const message = {
      Records: [
        {
          s3: {
            bucket: {
              name: bucket
            },
            object: {
              key: key
            }
          }
        }
      ]
    };
    
    try {
      await sqs.send(
        new SendMessageCommand({
          QueueUrl: queueUrl,
          MessageBody: JSON.stringify(message),
          MessageAttributes: {
            ChunkIndex: {
              DataType: 'Number',
              StringValue: (index + 1).toString()
            },
            TotalChunks: {
              DataType: 'Number', 
              StringValue: chunkS3Uris.length.toString()
            },
            OriginalFile: {
              DataType: 'String',
              StringValue: chunkS3Uri
            }
          }
        })
      );
      
      messagesSent++;
      console.log(`✅ Sent SQS message ${index + 1}/${chunkS3Uris.length} for: ${chunkS3Uri}`);
      
    } catch (error) {
      console.error(`❌ Failed to send SQS message for ${chunkS3Uri}:`, error);
      throw error;
    }
  }
  
  console.log(`🎯 Successfully sent ${messagesSent} SQS messages`);
  return messagesSent;
};

/**
 * Lambda handler for running elephant-cli prepare-permits command.
 * Handles both direct S3 events (from Step Function) and SQS messages containing S3 events.
 * 
 * @param {Object} event - Input event (S3 event or SQS message)
 * @returns {Promise<PreparePermitsOutput>} Success response with output S3 URIs
 */
export const handler = async (event) => {
  const startTime = Date.now();
  console.log("Event:", JSON.stringify(event, null, 2));
  console.log(`🚀 Prepare-permits Lambda handler started at: ${new Date().toISOString()}`);
  
  let s3Event;
  let bucket;
  let key;
  
  // Check if this is a direct S3 event (from Step Function) or SQS message
  if (event?.s3?.bucket?.name && event?.s3?.object?.key) {
    // Direct S3 event from Step Function
    console.log("Processing direct S3 event from Step Function");
    s3Event = event.s3;
    bucket = s3Event.bucket.name;
    key = decodeURIComponent(s3Event.object.key.replace(/\+/g, " "));
  } else if (event?.Records?.[0]?.eventSource === "aws:sqs") {
    // SQS message containing S3 event
    console.log("Processing SQS message");
    if (!Array.isArray(event.Records) || event.Records.length !== 1) {
      throw new Error("Expect exactly one SQS record per invocation");
    }
    
    const bodyRaw = event.Records[0].body;
    const parsed = JSON.parse(bodyRaw);
    
    // Extract S3 information from the SQS message
    if (!parsed?.Records?.[0]?.s3?.bucket?.name || !parsed?.Records?.[0]?.s3?.object?.key) {
      throw new Error("Missing S3 bucket/key in SQS message");
    }
    
    s3Event = parsed.Records[0].s3;
    bucket = s3Event.bucket.name;
    key = decodeURIComponent(s3Event.object.key.replace(/\+/g, " "));
  } else {
    throw new Error("Event must be either an S3 event or SQS message containing S3 event data");
  }
  
  console.log(`📂 Processing S3 object: s3://${bucket}/${key}`);
  
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "prepare-permits-"));
  
  try {
    // Download the CSV file from S3
    console.log("📥 Downloading CSV file from S3...");
    const csvFileName = path.basename(key);
    const localCsvPath = path.join(tempDir, csvFileName);
    
    const getResp = await s3.send(
      new GetObjectCommand({ Bucket: bucket, Key: key })
    );
    const csvBytes = await getResp.Body?.transformToByteArray();
    if (!csvBytes) {
      throw new Error("Failed to download CSV file body");
    }
    await fs.writeFile(localCsvPath, Buffer.from(csvBytes));
    console.log(`✅ Downloaded ${csvBytes.length} bytes to ${localCsvPath}`);
    
    // Check if portal.zip exists in the expected location, or use environment variable
    const portalZipS3Uri = process.env.PORTAL_ZIP_S3_URI;
    let portalZipPath;
    
    if (portalZipS3Uri) {
      console.log(`📦 Downloading portal.zip from: ${portalZipS3Uri}`);
      const { bucket: portalBucket, key: portalKey } = splitS3Uri(portalZipS3Uri);
      portalZipPath = path.join(tempDir, "portal.zip");
      
      const portalResp = await s3.send(
        new GetObjectCommand({ Bucket: portalBucket, Key: portalKey })
      );
      const portalBytes = await portalResp.Body?.transformToByteArray();
      if (!portalBytes) {
        throw new Error("Failed to download portal.zip file");
      }
      await fs.writeFile(portalZipPath, Buffer.from(portalBytes));
      console.log(`✅ Downloaded portal.zip (${portalBytes.length} bytes)`);
    } else {
      // Assume portal.zip is in the same directory as the CSV
      const portalKey = path.posix.join(path.posix.dirname(key), "portal.zip");
      console.log(`📦 Downloading portal.zip from same directory: s3://${bucket}/${portalKey}`);
      portalZipPath = path.join(tempDir, "portal.zip");
      
      try {
        const portalResp = await s3.send(
          new GetObjectCommand({ Bucket: bucket, Key: portalKey })
        );
        const portalBytes = await portalResp.Body?.transformToByteArray();
        if (!portalBytes) {
          throw new Error("Failed to download portal.zip file");
        }
        await fs.writeFile(portalZipPath, Buffer.from(portalBytes));
        console.log(`✅ Downloaded portal.zip (${portalBytes.length} bytes)`);
      } catch (error) {
        throw new Error(`Portal.zip not found at s3://${bucket}/${portalKey}. Set PORTAL_ZIP_S3_URI environment variable or place portal.zip in the same directory as the CSV file.`);
      }
    }
    
    // Get today's date for start and end parameters
    const todaysDate = getTodaysDate();
    console.log(`📅 Using today's date: ${todaysDate}`);
    
    // Use elephant-cli preparePermits function
    const outputZipPath = path.join(tempDir, "permits_output.zip");
    
    console.log(`🔄 Running preparePermits() function...`);
    const prepareStart = Date.now();
    
    try {
      // Build preparePermits options with correct signature
      const prepareOptions = { 
        start: todaysDate,
        end: todaysDate,
        output: outputZipPath
      };
      
      console.log("Calling preparePermits() with options:", prepareOptions);
      
      // Run the elephant-cli preparePermits function with correct signature
      await preparePermits(portalZipPath, prepareOptions);
      
      const prepareDuration = Date.now() - prepareStart;
      console.log(`✅ preparePermits() completed successfully in ${prepareDuration}ms`);
      
    } catch (error) {
      const prepareDuration = Date.now() - prepareStart;
      console.error(`❌ preparePermits() failed after ${prepareDuration}ms`);
      console.error(`Error: ${error.message}`);
      throw new Error(`elephant-cli preparePermits failed: ${error.message}`);
    }
    
    // Check if output file was created
    try {
      const outputStats = await fs.stat(outputZipPath);
      console.log(`📊 Output ZIP size: ${outputStats.size} bytes`);
    } catch (error) {
      throw new Error(`Output ZIP file not created at ${outputZipPath}`);
    }
    
    // Extract CSV from the output ZIP
    console.log("📦 Extracting CSV from output ZIP...");
    const zip = new AdmZip(outputZipPath);
    const zipEntries = zip.getEntries();
    
    // Find the CSV file in the ZIP
    const csvEntry = zipEntries.find(entry => entry.entryName.endsWith('.csv'));
    if (!csvEntry) {
      throw new Error("No CSV file found in the output ZIP");
    }
    
    console.log(`📄 Found CSV file in ZIP: ${csvEntry.entryName}`);
    const csvContent = csvEntry.getData().toString('utf8');
    
    // Write extracted CSV to temp file for chunking
    const extractedCsvPath = path.join(tempDir, "extracted_permits.csv");
    await fs.writeFile(extractedCsvPath, csvContent);
    console.log(`✅ Extracted CSV to: ${extractedCsvPath} (${csvContent.length} characters)`);
    
    // Split CSV into chunks and upload to S3
    console.log("📊 Splitting and uploading CSV chunks to S3...");
    const fileBase = path.posix.basename(key, path.extname(key));
    const baseOutputKey = path.posix.join(
      path.posix.dirname(key), 
      "outputs", 
      `${fileBase}_permits_${new Date().toISOString().split('T')[0]}`
    );
    
    // Get chunk size from environment variable (default: 100)
    const chunkSize = parseInt(process.env.CSV_CHUNK_SIZE || '100', 10);
    console.log(`📦 Using chunk size: ${chunkSize} rows per chunk`);
    
    const chunkS3Uris = await splitAndUploadCsv(extractedCsvPath, bucket, baseOutputKey, chunkSize);
    
    // Publish each chunk to SQS if queue URL is provided
    let sqsMessagesSent = 0;
    const sqsQueueUrl = process.env.CHUNK_SQS_QUEUE_URL;
    
    if (sqsQueueUrl && chunkS3Uris.length > 0) {
      console.log(`📨 Publishing ${chunkS3Uris.length} chunks to SQS queue: ${sqsQueueUrl}`);
      sqsMessagesSent = await publishChunksToSqs(chunkS3Uris, sqsQueueUrl);
    } else if (!sqsQueueUrl) {
      console.log("⚠️ CHUNK_SQS_QUEUE_URL not set, skipping SQS publishing");
    } else {
      console.log("⚠️ No chunks created, skipping SQS publishing");
    }
    
    const portalZipS3UriResult = portalZipS3Uri || `s3://${bucket}/${path.posix.join(path.posix.dirname(key), "portal.zip")}`;
    
    console.log(`✅ Created ${chunkS3Uris.length} CSV chunks and sent ${sqsMessagesSent} SQS messages`);
    
    // Total timing summary
    const totalDuration = Date.now() - startTime;
    console.log(`\n🎯 TIMING SUMMARY:`);
    console.log(`   TOTAL:       ${totalDuration}ms (${(totalDuration/1000).toFixed(2)}s)`);
    console.log(`🏁 Prepare-permits Lambda handler completed at: ${new Date().toISOString()}\n`);

    return { 
      chunk_s3_uris: chunkS3Uris,
      portal_zip_s3_uri: portalZipS3UriResult,
      total_chunks: chunkS3Uris.length,
      sqs_messages_sent: sqsMessagesSent
    };
    
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
};
