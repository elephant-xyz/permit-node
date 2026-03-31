import {
  GetObjectCommand,
  S3Client,
  PutObjectCommand,
} from "@aws-sdk/client-s3";
import { promises as fs } from "fs";
import path from "path";
import { prepare } from "@elephant-xyz/cli/lib";

const RE_S3PATH = /^s3:\/\/([^/]+)\/(.*)$/i;

/**
 * Splits an Amazon S3 URI into its bucket name and object key.
 *
 * @param {string} s3Uri - A valid S3 URI in the format `s3://<bucket>/<key>`.
 *   Example: `s3://my-bucket/folder/file.txt`
 *
 * @returns {{ bucket: string, key: string }} An object containing:
 *   - `bucket` {string} The S3 bucket name.
 *   - `key` {string} The S3 object key (path within the bucket).
 *
 * @throws {Error} If the input is not a valid S3 URI or does not include both bucket and key.
 */
const splitS3Uri = (s3Uri) => {
  const match = RE_S3PATH.exec(s3Uri);

  if (!match) {
    throw new Error("S3 path should be like: s3://bucket/object");
  }

  const [, bucket, key] = match;
  return { bucket, key };
};

/**
 * Lambda handler for processing orders and storing receipts in S3.
 * @param {Object} event - Input event containing order details
 * @param {string} event.input_s3_uri - S3 URI of input file
 * @param {string} event.output_s3_uri_prefix - S3 URI prefix for output files
 * @param {boolean} event.browser - Whether to run in headless browser
 * @returns {Promise<string>} Success message
 */
export const handler = async (event) => {
  const startTime = Date.now();
  console.log("Event:", event);
  console.log(`🚀 Lambda handler started at: ${new Date().toISOString()}`);
  
  if (!event || !event.input_s3_uri) {
    throw new Error("Missing required field: input_s3_uri");
  }
  const { bucket, key } = splitS3Uri(event.input_s3_uri);
  console.log("Bucket:", bucket);
  console.log("Key:", key);
  const s3 = new S3Client({});

  const tempDir = await fs.mkdtemp("/tmp/prepare-");
  try {
    // S3 Download Phase
    console.log("📥 Starting S3 download...");
    const s3DownloadStart = Date.now();
    
    const inputZip = path.join(tempDir, path.basename(key));
    const getResp = await s3.send(
      new GetObjectCommand({ Bucket: bucket, Key: key }),
    );
    const inputBytes = await getResp.Body?.transformToByteArray();
    if (!inputBytes) {
      throw new Error("Failed to download input object body");
    }
    await fs.writeFile(inputZip, Buffer.from(inputBytes));
    
    const s3DownloadDuration = Date.now() - s3DownloadStart;
    console.log(`✅ S3 download completed: ${s3DownloadDuration}ms (${(s3DownloadDuration/1000).toFixed(2)}s)`);
    console.log(`📊 Downloaded ${inputBytes.length} bytes from s3://${bucket}/${key}`);

    // Extract and log ZIP content before prepare
    console.log("🔍 Examining input ZIP content...");
    try {
      const AdmZip = await import('adm-zip');
      const zip = new AdmZip.default(inputZip);
      const zipEntries = zip.getEntries();
      
      console.log(`📦 ZIP contains ${zipEntries.length} files:`);
      
      zipEntries.forEach((entry, index) => {
        console.log(`  ${index + 1}. ${entry.entryName} (${entry.header.size} bytes)`);
        
        // If it's a CSV file, log its content
        if (entry.entryName.toLowerCase().endsWith('.csv')) {
          try {
            const csvContent = entry.getData().toString('utf8');
            const lines = csvContent.split('\n');
            console.log(`📋 CSV Content Preview (${entry.entryName}):`);
            console.log(`    Total lines: ${lines.length}`);
            console.log(`    Header: ${lines[0] || 'Empty'}`);
            
            // Log first few data rows
            const dataRows = lines.slice(1, 6).filter(line => line.trim());
            dataRows.forEach((row, i) => {
              console.log(`    Row ${i + 1}: ${row}`);
            });
            
            if (lines.length > 6) {
              console.log(`    ... and ${lines.length - 6} more rows`);
            }
          } catch (csvError) {
            console.log(`    ⚠️ Could not read CSV content: ${csvError.message}`);
          }
        }
      });
    } catch (zipError) {
      console.log(`⚠️ Could not examine ZIP content: ${zipError.message}`);
    }

    const outputZip = path.join(tempDir, "output.zip");
    const useBrowser = event.browser ?? true;
    
    console.log("Building prepare options...");
    console.log(`Event browser setting: ${event.browser} (using: ${useBrowser})`);
    
    // Configuration map for prepare flags
    const flagConfig = [
      {
        envVar: 'ELEPHANT_PREPARE_USE_BROWSER',
        optionKey: 'useBrowser',
        description: 'Force browser mode'
      },
      {
        envVar: 'ELEPHANT_PREPARE_NO_FAST',
        optionKey: 'noFast',
        description: 'Disable fast mode'
      },
      {
        envVar: 'ELEPHANT_PREPARE_NO_CONTINUE',
        optionKey: 'noContinue',
        description: 'Disable continue mode'
      }
    ];
    
    // Build prepare options based on environment variables
    const prepareOptions = { useBrowser };
    
    console.log("Checking environment variables for prepare flags:");
    
    for (const { envVar, optionKey, description } of flagConfig) {
      if (process.env[envVar] === 'true') {
        prepareOptions[optionKey] = true;
        console.log(`✓ ${envVar}='true' → adding ${optionKey}: true (${description})`);
      } else {
        console.log(`✗ ${envVar}='${process.env[envVar]}' → not adding ${optionKey} flag (${description})`);
      }
    }
    
    // Prepare Phase (Main bottleneck)
    console.log("🔄 Starting prepare() function...");
    const prepareStart = Date.now();
    console.log("Calling prepare() with these options...");
    
    await prepare(inputZip, outputZip, prepareOptions);
    
    const prepareDuration = Date.now() - prepareStart;
    console.log(`✅ Prepare function completed: ${prepareDuration}ms (${(prepareDuration/1000).toFixed(2)}s)`);
    console.log(`🔍 PERFORMANCE: Local=2s, Lambda=${(prepareDuration/1000).toFixed(1)}s - ${prepareDuration > 3000 ? '⚠️ SLOW' : '✅ OK'}`);
    
    // Check output file size
    const outputStats = await fs.stat(outputZip);
    console.log(`📊 Output file size: ${outputStats.size} bytes`);

    // Determine upload destination
    let outBucket = bucket;
    let outKey = key;
    if (event.output_s3_uri_prefix) {
      const { bucket: outB, key: outPrefix } = splitS3Uri(
        event.output_s3_uri_prefix,
      );
      outBucket = outB;
      outKey = path.posix.join(outPrefix.replace(/\/$/, ""), "output.zip");
    } else {
      // Default: write next to input with a suffix
      const dir = path.posix.dirname(key);
      const base = path.posix.basename(key, path.extname(key));
      outKey = path.posix.join(dir, `${base}.prepared.zip`);
    }

    // S3 Upload Phase
    console.log("📤 Starting S3 upload...");
    const s3UploadStart = Date.now();
    
    const outputBody = await fs.readFile(outputZip);
    await s3.send(
      new PutObjectCommand({
        Bucket: outBucket,
        Key: outKey,
        Body: outputBody,
      }),
    );
    
    const s3UploadDuration = Date.now() - s3UploadStart;
    console.log(`✅ S3 upload completed: ${s3UploadDuration}ms (${(s3UploadDuration/1000).toFixed(2)}s)`);
    console.log(`📊 Uploaded ${outputBody.length} bytes to s3://${outBucket}/${outKey}`);
    
    // Total timing summary
    const totalDuration = Date.now() - startTime;
    console.log(`\n🎯 TIMING SUMMARY:`);
    console.log(`   S3 Download: ${s3DownloadDuration}ms (${(s3DownloadDuration/1000).toFixed(2)}s)`);
    console.log(`   Prepare:     ${prepareDuration}ms (${(prepareDuration/1000).toFixed(2)}s)`);
    console.log(`   S3 Upload:   ${s3UploadDuration}ms (${(s3UploadDuration/1000).toFixed(2)}s)`);
    console.log(`   TOTAL:       ${totalDuration}ms (${(totalDuration/1000).toFixed(2)}s)`);
    console.log(`🏁 Lambda handler completed at: ${new Date().toISOString()}\n`);

    return { output_s3_uri: `s3://${outBucket}/${outKey}` };
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
};
