import {
  GetObjectCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import { promises as fs } from "fs";
import path from "path";
import os from "os";
import AdmZip from "adm-zip";
import { transform, validate } from "@elephant-xyz/cli/lib";
import { parse } from "csv-parse/sync";

/**
 * @typedef {Object} PreOutput
 * @property {string} input_s3_uri - S3 URI of input created for prepare step
 * @property {string} output_prefix - S3 URI prefix where prepare should write
 */

const s3 = new S3Client({});

/**
 * Convert CSV file to JSON array
 * @param {string} csvPath - Path to CSV file
 * @returns {Promise<Object[]>} - Array of objects representing CSV rows
 */
async function csvToJson(csvPath) {
  try {
    const csvContent = await fs.readFile(csvPath, "utf8");
    const records = parse(csvContent, {
      columns: true,
      skip_empty_lines: true,
      trim: true,
    });
    return records;
  } catch (error) {
    return [];
  }
}

/**
 * Build paths and derive prepare input from SQS/S3 event message.
 * - Extracts bucket/key from S3 event in SQS body
 * - Produces output prefix and input path for prepare Lambda
 *
 * @param {any} event - Original SQS body JSON (already parsed by starter)
 * @returns {Promise<PreOutput>}
 */
export const handler = async (event) => {
  console.log(`Event is : ${JSON.stringify(event)}`);
  const base = { component: "pre", at: new Date().toISOString() };
  let tmp;
  try {
    const rec = event;
    if (!rec?.s3?.bucket?.name || !rec?.s3?.object?.key) {
      throw new Error("Missing S3 bucket/key in message");
    }
    const bucket = rec.s3.bucket.name;
    const key = decodeURIComponent(rec.s3.object.key.replace(/\+/g, " "));
    const fileBase = path.posix.basename(key, path.extname(key));
    const outputPrefix =
      (process.env.OUTPUT_BASE_URI || `s3://${bucket}/outputs`).replace(
        /\/$/,
        "",
      ) + `/${fileBase}`;
    const inputS3Uri = `s3://${bucket}/${key}`;

    // Download CSV and create seed input.zip
    tmp = await fs.mkdtemp(path.join(os.tmpdir(), "pre-"));
    const csvPath = path.join(tmp, "seed.csv");
    const get = await s3.send(
      new GetObjectCommand({ Bucket: bucket, Key: key }),
    );
    const csvBytes = await get.Body?.transformToByteArray();
    if (!csvBytes) throw new Error("Failed to download input CSV");
    await fs.writeFile(csvPath, Buffer.from(csvBytes));
    
    // Log original CSV content
    console.log("🔍 Original CSV Content Analysis:");
    try {
      const csvContent = Buffer.from(csvBytes).toString('utf8');
      const lines = csvContent.split('\n');
      console.log(`📊 CSV Statistics:`);
      console.log(`    Total lines: ${lines.length}`);
      console.log(`    File size: ${csvBytes.length} bytes`);
      console.log(`    Header: ${lines[0] || 'Empty'}`);
      
      // Log first few data rows
      const dataRows = lines.slice(1, 6).filter(line => line.trim());
      console.log(`📋 Sample Data Rows:`);
      dataRows.forEach((row, i) => {
        console.log(`    Row ${i + 1}: ${row}`);
      });
      
      if (lines.length > 6) {
        console.log(`    ... and ${lines.length - 6} more rows`);
      }
      
      // If header contains URL-like fields, highlight them
      const header = lines[0] || '';
      const urlFields = header.split(',').map((field, index) => ({ field: field.trim(), index }))
        .filter(({field}) => field.toLowerCase().includes('url') || field.toLowerCase().includes('link') || field.toLowerCase().includes('address'));
      
      if (urlFields.length > 0) {
        console.log(`🔗 Detected URL/Address fields:`);
        urlFields.forEach(({field, index}) => {
          console.log(`    Column ${index + 1}: ${field}`);
        });
      }
    } catch (error) {
      console.log(`⚠️ Could not analyze CSV content: ${error.message}`);
    }
    const seedInputZip = path.join(tmp, "input.zip");
    const inZip = new AdmZip();
    inZip.addLocalFile(csvPath, "", "seed.csv");
    inZip.writeZip(seedInputZip);

    // Transform and validate seed
    const seedOutputZip = path.join(tmp, "seed_output.zip");
    const transformOptions = {
      inputZip: seedInputZip,
      outputZip: seedOutputZip,
      cwd: tmp,
    };
    console.log(transformOptions);

    const transformResult = await transform(transformOptions);
    if (!transformResult.success) throw new Error(transformResult.error);
    console.log("Transform complete");

    const validationResult = await validate({ input: seedOutputZip, cwd: tmp });
    if (!validationResult.success) {
      // Try to read submit_errors.csv and log as JSON
      const submitErrorsPath = path.join(tmp, "submit_errors.csv");
      let submitErrorsS3Uri = null;

      try {
        const submitErrors = await csvToJson(submitErrorsPath);

        // Upload submit_errors.csv to S3
        try {
          const submitErrorsCsv = await fs.readFile(submitErrorsPath);
          const errorFileKey = `${runPrefix.replace(/^s3:\/\//, "")}/submit_errors.csv`;
          const [errorBucket, ...errorParts] = errorFileKey.split("/");
          await s3.send(
            new PutObjectCommand({
              Bucket: errorBucket,
              Key: errorParts.join("/"),
              Body: submitErrorsCsv,
            }),
          );
          submitErrorsS3Uri = `s3://${errorBucket}/${errorParts.join("/")}`;
        } catch (uploadError) {
          console.error(`Failed to upload submit_errors.csv: ${uploadError}`);
        }

        console.error(
          JSON.stringify({
            ...base,
            level: "error",
            msg: "validation_failed",
            error: validationResult.error,
            submit_errors: submitErrors,
            submit_errors_s3_uri: submitErrorsS3Uri,
          }),
        );
      } catch (csvError) {
        console.error(
          JSON.stringify({
            ...base,
            level: "error",
            msg: "validation_failed",
            error: validationResult.error,
            submit_errors_read_error: String(csvError),
          }),
        );
      }

      const errorMessage = submitErrorsS3Uri
        ? `Validation failed. Submit errors CSV: ${submitErrorsS3Uri}`
        : "Validation failed";
      throw new Error(errorMessage);
    }
    console.log((await fs.readdir(tmp)).join("\n"));
    console.log("Validation complete");

    // Upload seed output
    const runPrefix = outputPrefix;
    const seedOutKey = `${runPrefix.replace(/^s3:\/\//, "")}/seed_output.zip`;
    const [outBucket, ...parts] = seedOutKey.split("/");
    const seedKey = parts.join("/");
    const seedBody = await fs.readFile(seedOutputZip);
    await s3.send(
      new PutObjectCommand({ Bucket: outBucket, Key: seedKey, Body: seedBody }),
    );

    // Build county prep input.zip from seed output
    const seedExtractDir = path.join(tmp, "seed_extract");
    await fs.mkdir(seedExtractDir, { recursive: true });
    const seedZip = new AdmZip(seedOutputZip);
    seedZip.extractAllTo(seedExtractDir, true);
    const countyPrepZip = path.join(tmp, "county_prep_input.zip");
    const addr = path.join(seedExtractDir, "data", "unnormalized_address.json");
    const seed = path.join(seedExtractDir, "data", "property_seed.json");
    const outZip = new AdmZip();
    outZip.addLocalFile(addr, "", "unnormalized_address.json");
    outZip.addLocalFile(seed, "", "property_seed.json");
    outZip.writeZip(countyPrepZip);
    const countyPrepKeyFull = `${runPrefix.replace(/^s3:\/\//, "")}/county_prep/input.zip`;
    const countyBody = await fs.readFile(countyPrepZip);
    const [cpBucket, ...cpParts] = countyPrepKeyFull.split("/");
    await s3.send(
      new PutObjectCommand({
        Bucket: cpBucket,
        Key: cpParts.join("/"),
        Body: countyBody,
      }),
    );

    const out = {
      input_s3_uri: inputS3Uri,
      output_prefix: outputPrefix,
      seed_output_s3_uri: `s3://${outBucket}/${seedKey}`,
      county_prep_input_s3_uri: `s3://${cpBucket}/${cpParts.join("/")}`,
    };
    console.log(
      JSON.stringify({ ...base, level: "info", msg: "prepared", out }),
    );
    return out;
  } catch (err) {
    console.error(
      JSON.stringify({
        ...base,
        level: "error",
        msg: "failed",
        error: String(err),
      }),
    );
    throw err;
  } finally {
    try {
      if (tmp) await fs.rm(tmp, { recursive: true, force: true });
    } catch {}
  }
};
