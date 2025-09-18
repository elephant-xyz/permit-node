import {
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { promises as fs } from "fs";
import path from "path";
import os from "os";
import { preparePermitPages } from "@elephant-xyz/cli/lib";
import AdmZip from "adm-zip";

/**
 * @typedef {Object} PreparePermitPagesOutput
 * @property {string} output_s3_uri - S3 URI of the generated ZIP file
 * @property {string} input_csv_s3_uri - S3 URI of the input CSV chunk
 * @property {number} processing_time_ms - Time taken to process in milliseconds
 */

const s3 = new S3Client({});

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
 * Lambda handler for running elephant-cli prepare-permit-pages command.
 * Reads SQS message containing CSV chunk location, creates ZIP with CSV, runs prepare-permit-pages, and uploads result to S3.
 * 
 * @param {Object} event - Input event from SQS message
 * @param {Object} event.Records - SQS records array  
 * @param {string} event.Records[0].body - JSON string containing S3 event info for CSV chunk
 * @returns {Promise<PreparePermitPagesOutput>} Success response with output S3 URI
 */
export const handler = async (event) => {
  const startTime = Date.now();
  console.log("Event:", JSON.stringify(event, null, 2));
  console.log(`🚀 Prepare-permit-pages Lambda handler started at: ${new Date().toISOString()}`);
  
  // Parse SQS message
  if (!event || !Array.isArray(event.Records) || event.Records.length !== 1) {
    throw new Error("Expect exactly one SQS record per invocation");
  }
  
  const bodyRaw = event.Records[0].body;
  const parsed = JSON.parse(bodyRaw);
  
  // Extract S3 information from the message
  if (!parsed?.Records?.[0]?.s3?.bucket?.name || !parsed?.Records?.[0]?.s3?.object?.key) {
    throw new Error("Missing S3 bucket/key in SQS message");
  }
  
  const s3Event = parsed.Records[0].s3;
  const bucket = s3Event.bucket.name;
  const key = decodeURIComponent(s3Event.object.key.replace(/\+/g, " "));
  
  console.log(`📂 Processing CSV chunk: s3://${bucket}/${key}`);
  
  // Extract chunk information from SQS message attributes
  const sqsRecord = event.Records[0];
  const messageAttributes = sqsRecord.messageAttributes || {};
  const chunkIndex = messageAttributes.ChunkIndex?.stringValue || "unknown";
  const totalChunks = messageAttributes.TotalChunks?.stringValue || "unknown";
  
  console.log(`📊 Processing chunk ${chunkIndex} of ${totalChunks}`);
  
  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "prepare-permit-pages-"));
  
  try {
    // Download the CSV chunk from S3
    console.log("📥 Downloading CSV chunk from S3...");
    const csvFileName = path.basename(key);
    const localCsvPath = path.join(tempDir, csvFileName);
    
    const getResp = await s3.send(
      new GetObjectCommand({ Bucket: bucket, Key: key })
    );
    const csvBytes = await getResp.Body?.transformToByteArray();
    if (!csvBytes) {
      throw new Error("Failed to download CSV chunk file body");
    }
    await fs.writeFile(localCsvPath, Buffer.from(csvBytes));
    console.log(`✅ Downloaded ${csvBytes.length} bytes to ${localCsvPath}`);
    
    // Create ZIP file containing the CSV
    console.log("📦 Creating ZIP file with CSV chunk...");
    const zipFileName = path.basename(key, '.csv') + '.zip';
    const zipFilePath = path.join(tempDir, zipFileName);
    
    const zip = new AdmZip();
    zip.addLocalFile(localCsvPath, "", path.basename(localCsvPath));
    zip.writeZip(zipFilePath);
    
    const zipStats = await fs.stat(zipFilePath);
    console.log(`✅ Created ZIP file: ${zipFilePath} (${zipStats.size} bytes)`);
    
    // Use elephant-cli preparePermitPages function
    const outputZipPath = path.join(tempDir, "output.zip");
    
    console.log(`🔄 Running preparePermitPages() function...`);
    const cmdStart = Date.now();
    
    try {
      // Build preparePermitPages options
      const prepareOptions = { 
        useBrowser: true
      };
      
      console.log("Calling preparePermitPages() with options:", prepareOptions);
      
      // Run the elephant-cli preparePermitPages function
      await preparePermitPages(zipFilePath, outputZipPath, prepareOptions);
      
      const cmdDuration = Date.now() - cmdStart;
      console.log(`✅ preparePermitPages() completed successfully in ${cmdDuration}ms`);
      
    } catch (error) {
      const cmdDuration = Date.now() - cmdStart;
      console.error(`❌ preparePermitPages() failed after ${cmdDuration}ms`);
      console.error(`Error: ${error.message}`);
      throw new Error(`elephant-cli preparePermitPages failed: ${error.message}`);
    }
    
    // Check if output file was created
    try {
      const outputStats = await fs.stat(outputZipPath);
      console.log(`📊 Output ZIP size: ${outputStats.size} bytes`);
    } catch (error) {
      throw new Error(`Output ZIP file not created at ${outputZipPath}`);
    }
    
    // Upload the result ZIP to S3
    console.log("📤 Uploading output ZIP to S3...");
    
    // Create output key based on input key, replacing chunk CSV with result ZIP
    const outputKey = key
      .replace(/\.csv$/, '.zip')
      .replace(/\/outputs\//, '/results/')
      .replace(/_chunk_(\d+)\.zip$/, '_pages_chunk_$1.zip');
    
    const outputBody = await fs.readFile(outputZipPath);
    await s3.send(
      new PutObjectCommand({
        Bucket: bucket,
        Key: outputKey,
        Body: outputBody,
        ContentType: 'application/zip'
      })
    );
    
    const outputS3Uri = `s3://${bucket}/${outputKey}`;
    const inputCsvS3Uri = `s3://${bucket}/${key}`;
    
    console.log(`✅ Uploaded output ZIP to: ${outputS3Uri}`);
    
    // Total timing summary
    const totalDuration = Date.now() - startTime;
    console.log(`\n🎯 TIMING SUMMARY:`);
    console.log(`   TOTAL:       ${totalDuration}ms (${(totalDuration/1000).toFixed(2)}s)`);
    console.log(`🏁 Prepare-permit-pages Lambda handler completed at: ${new Date().toISOString()}\n`);

    return { 
      output_s3_uri: outputS3Uri,
      input_csv_s3_uri: inputCsvS3Uri,
      processing_time_ms: totalDuration
    };
    
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
};
