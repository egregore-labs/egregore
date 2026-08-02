#!/usr/bin/env node
/**
 * End-to-end tests for the Google Workspace connector.
 *
 * Run modes:
 *   npx tsx test/e2e.ts              — unit tests only (no Google credentials needed)
 *   npx tsx test/e2e.ts --live       — full e2e with live Google APIs (requires auth)
 *   npx tsx test/e2e.ts --api        — test API promotion endpoint
 *
 * Exit codes:
 *   0 = all tests passed
 *   1 = test failure
 */

import { execSync } from "child_process";
import { existsSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";
import { extractMessageContent } from "../src/gmail.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONNECTOR_DIR = resolve(__dirname, "..");
const PROJECT_ROOT = resolve(CONNECTOR_DIR, "../..");
const CLI = `npx tsx ${CONNECTOR_DIR}/src/index.ts`;

const isLive = process.argv.includes("--live");
const isApi = process.argv.includes("--api");

let passed = 0;
let failed = 0;
let skipped = 0;

function test(name: string, fn: () => void | Promise<void>) {
  return { name, fn };
}

function skip(name: string) {
  return { name, fn: null };
}

async function run(tests: Array<{ name: string; fn: (() => void | Promise<void>) | null }>) {
  console.log(`\nRunning ${tests.length} tests...\n`);

  for (const t of tests) {
    if (!t.fn) {
      skipped++;
      console.log(`  SKIP  ${t.name}`);
      continue;
    }
    try {
      await t.fn();
      passed++;
      console.log(`  PASS  ${t.name}`);
    } catch (err: unknown) {
      failed++;
      const e = err as { message?: string };
      console.log(`  FAIL  ${t.name}`);
      console.log(`        ${e.message}`);
    }
  }

  console.log(`\n${passed} passed, ${failed} failed, ${skipped} skipped\n`);
  process.exit(failed > 0 ? 1 : 0);
}

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(`Assertion failed: ${message}`);
}

function assertContains(haystack: string, needle: string) {
  if (!haystack.includes(needle)) {
    throw new Error(`Expected output to contain "${needle}", got: ${haystack.slice(0, 200)}`);
  }
}

function exec(cmd: string): string {
  return execSync(cmd, {
    encoding: "utf-8",
    timeout: 30_000,
    cwd: CONNECTOR_DIR,
    env: { ...process.env, NODE_NO_WARNINGS: "1" },
    stdio: ["pipe", "pipe", "pipe"],
  }).trim();
}

function execMayFail(cmd: string): { stdout: string; stderr: string; code: number } {
  try {
    const stdout = execSync(cmd, {
      encoding: "utf-8",
      timeout: 30_000,
      cwd: CONNECTOR_DIR,
      env: { ...process.env, NODE_NO_WARNINGS: "1" },
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    return { stdout, stderr: "", code: 0 };
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; status?: number };
    return {
      stdout: (e.stdout ?? "").toString().trim(),
      stderr: (e.stderr ?? "").toString().trim(),
      code: e.status ?? 1,
    };
  }
}

// =============================================================================
// UNIT TESTS (no Google credentials needed)
// =============================================================================

const unitTests = [
  test("gmail: extracts nested plain-text body and attachment metadata", () => {
    const encoded = Buffer.from("Nested message body", "utf-8").toString("base64url");
    const result = extractMessageContent({
      mimeType: "multipart/mixed",
      parts: [
        {
          mimeType: "multipart/alternative",
          parts: [{ mimeType: "text/plain", body: { data: encoded } }],
        },
        {
          filename: "decision.pdf",
          mimeType: "application/pdf",
          body: { attachmentId: "attachment-123", size: 42 },
        },
      ],
    });
    assert(result.body === "Nested message body", "Should extract recursively nested text/plain");
    assert(result.attachments.length === 1, "Should find one attachment");
    assert(result.attachments[0].id === "attachment-123", "Attachment ID should match");
    assert(result.attachments[0].filename === "decision.pdf", "Filename should match");
  }),

  test("gmail: falls back to nested HTML when plain text is absent", () => {
    const encoded = Buffer.from("<p>HTML message</p>", "utf-8").toString("base64url");
    const result = extractMessageContent({
      mimeType: "multipart/alternative",
      parts: [{ mimeType: "text/html", body: { data: encoded } }],
    });
    assert(result.body === "<p>HTML message</p>", "Should fall back to HTML body");
  }),

  test("CLI: help command shows usage", () => {
    const out = exec(`${CLI} help`);
    assertContains(out, "connector-google <command>");
    assertContains(out, "drive list");
    assertContains(out, "drive search-all");
    assertContains(out, "gmail list");
    assertContains(out, "gmail search-all");
    assertContains(out, "gmail attachment");
    assertContains(out, "calendar list");
    assertContains(out, "calendar list-all");
    assertContains(out, "--account EMAIL");
    assertContains(out, "docs get");
    assertContains(out, "sheets get");
    assertContains(out, "promote");
  }),

  test("CLI: --help flag works", () => {
    const out = exec(`${CLI} --help`);
    assertContains(out, "connector-google <command>");
  }),

  test("CLI: status shows connector state", () => {
    const out = exec(`${CLI} status`);
    assertContains(out, "Google Workspace Connector Status");
    assertContains(out, "Org enabled:");
    assertContains(out, "User connected:");
    assertContains(out, "Services:");
  }),

  test("CLI: auth accounts lists connected accounts", () => {
    const out = exec(`${CLI} auth accounts`);
    const result = JSON.parse(out);
    assert(Array.isArray(result.accounts), "Expected accounts array");
    assert(typeof result.active === "string" || result.active === undefined, "Expected active account");
  }),

  test("CLI: unknown command exits with error", () => {
    const r = execMayFail(`${CLI} nonexistent`);
    assert(r.code !== 0, "Should exit non-zero for unknown command");
    assertContains(r.stderr, "Unknown command: nonexistent");
  }),

  test("CLI: enable with no args shows available services", () => {
    const out = exec(`${CLI} enable`);
    assertContains(out, "Available services:");
  }),

  test("CLI: enable sets services in state", () => {
    const statePath = join(PROJECT_ROOT, ".egregore-state.json");
    const originalState = readFileSync(statePath, "utf-8");

    try {
      exec(`${CLI} enable drive gmail`);
      const state = JSON.parse(readFileSync(statePath, "utf-8"));
      assert(
        JSON.stringify(state.google_services) === JSON.stringify(["drive", "gmail"]),
        `Expected ["drive","gmail"], got ${JSON.stringify(state.google_services)}`
      );
    } finally {
      // Restore original state
      writeFileSync(statePath, originalState);
    }
  }),

  test("CLI: context list works with empty cache", () => {
    const out = exec(`${CLI} context list`);
    // Should either show items or "No cached items."
    assert(out.includes("No cached items") || out.includes("["), "Expected cache output");
  }),

  test("CLI: context clear works", () => {
    const out = exec(`${CLI} context clear`);
    assertContains(out, "Cleared");
  }),

  test("CLI: context show with nonexistent ID exits with error", () => {
    const r = execMayFail(`${CLI} context show nonexistent-id-12345`);
    assert(r.code !== 0, "Should exit non-zero for missing item");
    assertContains(r.stderr, "not found in cache");
  }),

  test("CLI: promote with missing args exits with error", () => {
    const r = execMayFail(`${CLI} promote`);
    assert(r.code !== 0, "Should exit non-zero with missing args");
    assertContains(r.stderr, "Usage: promote");
  }),

  test("CLI: drive with no subcommand exits with error", () => {
    const r = execMayFail(`${CLI} drive`);
    assert(r.code !== 0, "Should exit non-zero");
    assertContains(r.stderr, "Usage: drive");
  }),

  test("CLI: gmail with no subcommand exits with error", () => {
    const r = execMayFail(`${CLI} gmail`);
    assert(r.code !== 0, "Should exit non-zero");
    assertContains(r.stderr, "Usage: gmail");
  }),

  test("CLI: calendar with no subcommand exits with error", () => {
    const r = execMayFail(`${CLI} calendar`);
    assert(r.code !== 0, "Should exit non-zero");
    assertContains(r.stderr, "Usage: calendar");
  }),

  test("CLI: docs with no subcommand exits with error", () => {
    const r = execMayFail(`${CLI} docs`);
    assert(r.code !== 0, "Should exit non-zero");
    assertContains(r.stderr, "Usage: docs");
  }),

  test("CLI: sheets with no subcommand exits with error", () => {
    const r = execMayFail(`${CLI} sheets`);
    assert(r.code !== 0, "Should exit non-zero");
    assertContains(r.stderr, "Usage: sheets");
  }),

  test("context: cache dirs are created", () => {
    const contextRoot = join(homedir(), ".egregore", "context", "google");
    // The context module creates these on first use
    exec(`${CLI} context list`);
    for (const svc of ["drive", "gmail", "calendar", "docs", "sheets"]) {
      assert(existsSync(join(contextRoot, svc)), `Missing context dir: ${svc}`);
    }
  }),

  test("config: egregore.json has connectors.google section", () => {
    const config = JSON.parse(readFileSync(join(PROJECT_ROOT, "egregore.json"), "utf-8"));
    assert(config.connectors?.google?.enabled === true, "connectors.google.enabled should be true");
    assert(Array.isArray(config.connectors.google.services), "services should be an array");
    assert(config.connectors.google.services.includes("drive"), "services should include drive");
  }),

  test("promote: builds valid JSON payload", () => {
    // First cache a test item
    const contextDir = join(homedir(), ".egregore", "context", "google", "docs");
    mkdirSync(contextDir, { recursive: true });
    writeFileSync(
      join(contextDir, "test-doc-123.json"),
      JSON.stringify({
        title: "Test Document",
        content: "This is test content for the promotion pipeline.",
        fetchedAt: new Date().toISOString(),
      })
    );

    const out = exec(`${CLI} promote docs test-doc-123`);
    const payload = JSON.parse(out);
    assert(payload.google_id === "test-doc-123", `Expected google_id test-doc-123, got ${payload.google_id}`);
    assert(payload.title === "Test Document", `Expected title "Test Document", got ${payload.title}`);
    assert(payload.service === "docs", `Expected service "docs", got ${payload.service}`);
    assert(payload.file_path.startsWith("knowledge/sources/google/"), "file_path should start with knowledge/sources/google/");
    assert(payload.file_path.includes("docs-test-document"), "file_path should include docs-test-document slug");

    // Cleanup
    rmSync(join(contextDir, "test-doc-123.json"));
  }),

  test("bash shim: connector-google.sh delegates correctly", () => {
    const out = execSync(`bash ${PROJECT_ROOT}/bin/connector-google.sh help`, {
      encoding: "utf-8",
      timeout: 30_000,
    }).trim();
    assertContains(out, "connector-google <command>");
  }),

  test("types: all service types are valid", () => {
    // Verify the connector handles all 5 service types
    const services = ["drive", "gmail", "calendar", "docs", "sheets"];
    for (const svc of services) {
      const r = execMayFail(`${CLI} ${svc}`);
      // Should fail with "Usage:" not "Unknown command:"
      assert(!r.stderr.includes("Unknown command"), `${svc} should be a recognized command`);
    }
  }),
];

// =============================================================================
// LIVE TESTS (require Google OAuth — run with --live)
// =============================================================================

const liveTests = [
  test("auth: status shows connection info", async () => {
    const out = exec(`${CLI} auth status`);
    // If authenticated, shows "Status: connected"
    // If not, shows "Status: not connected"
    assert(
      out.includes("Status: connected") || out.includes("Status: not connected"),
      "Should show auth status"
    );
    if (!out.includes("Status: connected")) {
      throw new Error("Not authenticated — run 'bash bin/connector-google.sh auth' first");
    }
  }),

  test("drive: list returns files", async () => {
    const out = exec(`${CLI} drive list --max 5`);
    const result = JSON.parse(out);
    assert(result.ok === true, `Expected ok=true, got ${result.ok}: ${result.error}`);
    assert(Array.isArray(result.data.files), "Expected files array");
    console.log(`        (${result.data.files.length} files returned)`);
  }),

  test("drive: search returns results", async () => {
    const out = exec(`${CLI} drive search "test"`);
    const result = JSON.parse(out);
    assert(result.ok === true, `Expected ok=true, got ${result.ok}: ${result.error}`);
    assert(Array.isArray(result.data.files), "Expected files array");
  }),

  test("drive: get retrieves file metadata", async () => {
    // First list to get a file ID
    const listOut = exec(`${CLI} drive list --max 1`);
    const listResult = JSON.parse(listOut);
    if (!listResult.data.files.length) {
      throw new Error("No files in Drive to test with");
    }
    const fileId = listResult.data.files[0].id;

    const out = exec(`${CLI} drive get ${fileId}`);
    const result = JSON.parse(out);
    assert(result.ok === true, `Expected ok=true: ${result.error}`);
    assert(result.data.metadata.id === fileId, "File ID should match");
    console.log(`        (got: ${result.data.metadata.name})`);
  }),

  test("gmail: list returns messages", async () => {
    const out = exec(`${CLI} gmail list --max 3`);
    const result = JSON.parse(out);
    assert(result.ok === true, `Expected ok=true: ${result.error}`);
    assert(Array.isArray(result.data.messages), "Expected messages array");
    console.log(`        (${result.data.messages.length} messages returned)`);
  }),

  test("gmail: get retrieves message content", async () => {
    const listOut = exec(`${CLI} gmail list --max 1`);
    const listResult = JSON.parse(listOut);
    if (!listResult.data.messages.length) {
      throw new Error("No messages in Gmail to test with");
    }
    const msgId = listResult.data.messages[0].id;

    const out = exec(`${CLI} gmail get ${msgId}`);
    const result = JSON.parse(out);
    assert(result.ok === true, `Expected ok=true: ${result.error}`);
    assert(result.data.id === msgId, "Message ID should match");
    console.log(`        (subject: ${result.data.subject})`);
  }),

  test("gmail: search finds messages", async () => {
    const out = exec(`${CLI} gmail search "in:inbox"`);
    const result = JSON.parse(out);
    assert(result.ok === true, `Expected ok=true: ${result.error}`);
    assert(Array.isArray(result.data.messages), "Expected messages array");
  }),

  test("calendar: list returns events", async () => {
    const out = exec(`${CLI} calendar list`);
    const result = JSON.parse(out);
    assert(result.ok === true, `Expected ok=true: ${result.error}`);
    assert(Array.isArray(result.data.events), "Expected events array");
    console.log(`        (${result.data.events.length} events returned)`);
  }),

  test("sync: refreshes all services", async () => {
    const out = exec(`${CLI} sync`);
    assertContains(out, "Syncing:");
    assertContains(out, "Sync complete.");
    // At least one service should sync
    assert(
      out.includes("synced") || out.includes("failed"),
      "Should show sync results per service"
    );
  }),

  test("context: list shows cached items after sync", async () => {
    // sync first to populate cache
    exec(`${CLI} sync drive`);
    const out = exec(`${CLI} context list drive`);
    // Should have at least the latest-list.json cached
    assert(!out.includes("No cached items"), "Should have cached items after sync");
  }),

  test("drive: cached file matches live data", async () => {
    const listOut = exec(`${CLI} drive list --max 1`);
    const listResult = JSON.parse(listOut);
    if (!listResult.data.files.length) {
      throw new Error("No files to verify cache");
    }
    const fileId = listResult.data.files[0].id;
    const fileName = listResult.data.files[0].name;

    // Get should cache the file
    exec(`${CLI} drive get ${fileId}`);

    // Verify cache
    const cachePath = join(homedir(), ".egregore", "context", "google", "drive", `${fileId}.json`);
    assert(existsSync(cachePath), `Cache file should exist at ${cachePath}`);
    const cached = JSON.parse(readFileSync(cachePath, "utf-8"));
    assert(cached.metadata.name === fileName, "Cached name should match");
    assert(cached.fetchedAt, "Should have fetchedAt timestamp");
  }),
];

// =============================================================================
// API TESTS (require Egregore API — run with --api)
// =============================================================================

const apiTests = [
  test("api: promotion endpoint creates artifact", async () => {
    const envPath = join(PROJECT_ROOT, ".env");
    if (!existsSync(envPath)) {
      throw new Error("No .env file — API key required");
    }
    const envContent = readFileSync(envPath, "utf-8");
    const apiKeyMatch = envContent.match(/^EGREGORE_API_KEY=(.+)$/m);
    if (!apiKeyMatch) {
      throw new Error("EGREGORE_API_KEY not found in .env");
    }
    const apiKey = apiKeyMatch[1].trim();

    const configContent = readFileSync(join(PROJECT_ROOT, "egregore.json"), "utf-8");
    const config = JSON.parse(configContent);
    const apiUrl = config.api_url;

    const testPayload = {
      github_username: "test-e2e",
      google_id: `test-e2e-${Date.now()}`,
      title: "E2E Test Document",
      service: "docs",
      content: "This is an e2e test document.",
      file_path: "knowledge/sources/google/test-e2e.md",
      summary: "E2E test document for connector validation.",
      topics: ["test", "e2e"],
      mentioned_people: [],
      related_quests: [],
    };

    const resp = await fetch(`${apiUrl}/api/connectors/google/promote`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(testPayload),
    });

    const respBody = await resp.json() as { status: string; artifact_id?: string };
    assert(resp.ok, `Promote API returned ${resp.status}: ${JSON.stringify(respBody)}`);
    assert(respBody.status === "promoted", `Expected status=promoted, got ${respBody.status}`);
    console.log(`        (artifact_id: ${respBody.artifact_id})`);

    // Verify the artifact exists in the graph
    const verifyResp = await fetch(`${apiUrl}/api/graph/query`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        statement: "MATCH (a:Artifact {google_id: $gid}) RETURN a.title, a.origin, a.summary",
        parameters: { gid: testPayload.google_id },
      }),
    });

    assert(verifyResp.ok, "Graph verification query should succeed");
    const verifyData = (await verifyResp.json()) as { values?: unknown[][] };
    assert(verifyData.values && verifyData.values.length > 0, "Should find the artifact in the graph");
    console.log(`        (verified in graph: ${JSON.stringify(verifyData.values![0])})`);

    // Cleanup: delete the test artifact
    await fetch(`${apiUrl}/api/graph/query`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        statement: "MATCH (a:Artifact {google_id: $gid}) DETACH DELETE a",
        parameters: { gid: testPayload.google_id },
      }),
    });
  }),

  test("api: promotion dedup (MERGE on google_id)", async () => {
    const envContent = readFileSync(join(PROJECT_ROOT, ".env"), "utf-8");
    const apiKey = envContent.match(/^EGREGORE_API_KEY=(.+)$/m)![1].trim();
    const config = JSON.parse(readFileSync(join(PROJECT_ROOT, "egregore.json"), "utf-8"));
    const apiUrl = config.api_url;

    const testId = `test-dedup-${Date.now()}`;
    const payload = {
      github_username: "test-e2e",
      google_id: testId,
      title: "Dedup Test v1",
      service: "docs",
      content: "First version.",
      file_path: "knowledge/sources/google/test-dedup.md",
      summary: "First summary",
      topics: ["dedup-test"],
      mentioned_people: [],
      related_quests: [],
    };

    // Promote v1
    const resp1 = await fetch(`${apiUrl}/api/connectors/google/promote`, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    assert(resp1.ok, "First promote should succeed");

    // Promote v2 with updated summary
    payload.summary = "Updated summary";
    payload.title = "Dedup Test v2";
    const resp2 = await fetch(`${apiUrl}/api/connectors/google/promote`, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    assert(resp2.ok, "Second promote should succeed");

    // Verify only one artifact exists
    const countResp = await fetch(`${apiUrl}/api/graph/query`, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        statement: "MATCH (a:Artifact {google_id: $gid}) RETURN count(a) AS cnt, a.summary",
        parameters: { gid: testId },
      }),
    });
    const countData = (await countResp.json()) as { values?: unknown[][] };
    const count = countData.values?.[0]?.[0];
    assert(count === 1, `Expected 1 artifact, got ${count} (dedup failed)`);

    const summary = countData.values?.[0]?.[1];
    assert(summary === "Updated summary", `Summary should be updated, got: ${summary}`);

    // Cleanup
    await fetch(`${apiUrl}/api/graph/query`, {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        statement: "MATCH (a:Artifact {google_id: $gid}) DETACH DELETE a",
        parameters: { gid: testId },
      }),
    });
  }),

  test("api: google auth-url endpoint works", async () => {
    const envContent = readFileSync(join(PROJECT_ROOT, ".env"), "utf-8");
    const apiKey = envContent.match(/^EGREGORE_API_KEY=(.+)$/m)![1].trim();
    const config = JSON.parse(readFileSync(join(PROJECT_ROOT, "egregore.json"), "utf-8"));
    const apiUrl = config.api_url;

    const resp = await fetch(`${apiUrl}/api/connectors/google/auth-url`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });

    // May return 503 if GOOGLE_CLIENT_ID not configured on server — that's expected
    if (resp.status === 503) {
      console.log("        (503 — GOOGLE_CLIENT_ID not configured on server, expected for dev)");
      return;
    }
    assert(resp.ok, `Auth URL endpoint returned ${resp.status}`);
    const data = (await resp.json()) as { url: string };
    assertContains(data.url, "accounts.google.com");
  }),

  test("api: google status endpoint works", async () => {
    const envContent = readFileSync(join(PROJECT_ROOT, ".env"), "utf-8");
    const apiKey = envContent.match(/^EGREGORE_API_KEY=(.+)$/m)![1].trim();
    const config = JSON.parse(readFileSync(join(PROJECT_ROOT, "egregore.json"), "utf-8"));
    const apiUrl = config.api_url;

    const resp = await fetch(
      `${apiUrl}/api/connectors/google/status?github_username=test-e2e`,
      { headers: { Authorization: `Bearer ${apiKey}` } }
    );
    assert(resp.ok, `Status endpoint returned ${resp.status}`);
    const data = (await resp.json()) as { connected: boolean };
    assert(typeof data.connected === "boolean", "Should return connected boolean");
  }),
];

// =============================================================================
// RUNNER
// =============================================================================

const allTests = [
  ...unitTests,
  ...(isLive ? liveTests : liveTests.map((t) => skip(`[LIVE] ${t.name}`))),
  ...(isApi ? apiTests : apiTests.map((t) => skip(`[API] ${t.name}`))),
];

run(allTests);
