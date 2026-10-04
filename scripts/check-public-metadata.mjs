#!/usr/bin/env node
import { scanPullRequest } from "./lib/public-metadata-policy.mjs";

// Receive JSON on stdin, never interpolate a contributor's text into a shell.
// Bound the input and print only fixed field/rule names, including on failure.
try {
  if (process.argv.length !== 2) throw new Error("Unexpected arguments.");
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > 4 * 1024 * 1024) throw new Error("Event too large.");
    chunks.push(chunk);
  }
  const findings = scanPullRequest(JSON.parse(Buffer.concat(chunks).toString("utf8")));
  if (findings.length) {
    console.error("Public metadata check failed. Matching content is withheld.");
    for (const { field, rule } of findings) console.error(`${field}: [${rule}]`);
    process.exitCode = 1;
  } else {
    console.log("Public metadata check passed. Text still requires human privacy review.");
  }
} catch {
  console.error("Public metadata check could not complete. Review the event input privately.");
  process.exitCode = 1;
}
