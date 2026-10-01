#!/usr/bin/env node
// Trusted release-control code: never execute a module from a package archive.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";

const stable = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const sha = /^[a-f0-9]{40}$/;
function requireThat(condition, message) {
  if (!condition) throw new Error(message);
}
function evidence(value, name) {
  requireThat(typeof value === "string", `${name}: evidence URL required`);
  const url = new URL(value);
  requireThat(url.protocol === "https:" && !url.username && !url.password, `${name}: HTTPS evidence required`);
}
export function validateVersion(version) {
  requireThat(typeof version === "string" && stable.test(version), "stable publication requires a plain X.Y.Z version (no prerelease/build suffix)");
}
export function selectPublicationIntent(root, catalog, requested = "all") {
  const intent = JSON.parse(fs.readFileSync(path.join(root, ".github/stable-release-intent.json"), "utf8"));
  requireThat(intent.schema === "egregore-stable-intent/v1", "unsupported stable publication intent");
  requireThat(Array.isArray(catalog) && catalog.length > 0 && new Set(catalog).size === catalog.length, "invalid release catalog");
  requireThat(Array.isArray(intent.packages) && intent.packages.length === catalog.length &&
    new Set(intent.packages.map(p => p.name)).size === catalog.length, "intent must cover every active package exactly once");
  for (const entry of intent.packages) {
    requireThat(catalog.includes(entry.name), "unknown package in publication intent");
    const manifest = JSON.parse(fs.readFileSync(path.join(root, "packages", entry.name, "package.json"), "utf8"));
    requireThat(manifest.name === entry.name && manifest.version === entry.version, `publication intent version mismatch: ${entry.name}`);
    requireThat(["publish", "defer"].includes(entry.action), `explicit publish or defer action required: ${entry.name}`);
    requireThat(typeof entry.reason === "string" && entry.reason.trim().length > 0, `publication intent reason required: ${entry.name}`);
    if (entry.action === "publish") validateVersion(entry.version);
  }
  const selected = intent.packages.filter(p => p.action === "publish" && (requested === "all" || p.name === requested));
  requireThat(selected.length > 0, "No matching publication intent; select/version packages in the reviewed stable-release-intent.json before running a stable release. Deferred packages cannot be recovered by dispatch.");
  return { packages: selected.map(p => p.name), publish_intent: selected.map(({ name, version }) => ({ name, version })),
    deferred: intent.packages.filter(p => p.action === "defer") };
}

function validateSelectedIntent(packages, intent) {
  requireThat(Array.isArray(packages) && packages.length > 0 && new Set(packages).size === packages.length, "nonempty unique package selection required");
  requireThat(Array.isArray(intent) && intent.length === packages.length && new Set(intent.map(p => p.name)).size === packages.length &&
    intent.every(p => packages.includes(p.name)), "selected packages must match frozen publication intent");
  intent.forEach(p => validateVersion(p.version));
}

export function validateRegistryCandidate(candidate, latest, metadata, bytes) {
  validateVersion(candidate.version);
  validateVersion(latest);
  const wanted = candidate.version.split(".").map(BigInt);
  const current = latest.split(".").map(BigInt);
  for (let i = 0; i < 3; i++) {
    requireThat(wanted[i] >= current[i], "Refusing to move latest backwards");
    if (wanted[i] > current[i]) break;
  }
  if (metadata !== null) {
    const integrity = "sha512-" + crypto.createHash("sha512").update(bytes).digest("base64");
    requireThat(metadata.name === candidate.name && metadata.version === candidate.version && metadata.dist?.integrity === integrity,
      "Published version differs from the approved archive; bump the selected package version");
    requireThat(latest === candidate.version, "Approved version already exists but latest points elsewhere; explicit dist-tag recovery is required");
  }
}

function registryView(specifier, field, allowMissing = false) {
  try {
    return JSON.parse(execFileSync("npm", ["view", specifier, ...(field ? [field] : []), "--json"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
  } catch (error) {
    let response;
    try { response = JSON.parse(error.stdout); } catch { /* fail closed below */ }
    if (allowMissing && response?.error?.code === "E404") return null;
    throw new Error(`Registry lookup failed for ${specifier}; publication blocked`);
  }
}
export function releaseApprovers(config) {
  const names = config.release?.approvers ?? config.admins;
  requireThat(Array.isArray(names) && names.length > 0 && names.every(name => typeof name === "string" && /^[a-zA-Z0-9-]+$/.test(name)), "configured release approvers or admins required");
  return names.map(name => name.toLowerCase());
}

export function validateApproval(comment, pull, approvers, context, candidates) {
  requireThat(comment.user?.type === "User" && approvers.includes(comment.user.login?.toLowerCase()), "approval author is not a configured human release approver");
  requireThat(pull.merged_at && pull.merge_commit_sha === context.source_sha && pull.base?.ref === "main" && pull.base?.repo?.full_name === context.repository, "approval must belong to the merged main PR for this exact source SHA");
  requireThat(comment.issue_url === `https://api.github.com/repos/${context.repository}/issues/${pull.number}` && Number.isSafeInteger(comment.id), "approval comment belongs to another release PR");
  const match = comment.body?.match(/^APPROVE STABLE PUBLICATION\r?\n```json\r?\n([\s\S]+?)\r?\n```\s*$/);
  requireThat(match, "explicit stable publication approval and complete JSON receipt required");
  const receipt = JSON.parse(match[1]);
  validateReceipt(receipt, context, candidates);
  return receipt;
}

function githubPages(endpoint) {
  const pages = JSON.parse(execFileSync("gh", ["api", "--paginate", "--slurp", endpoint], { encoding: "utf8", maxBuffer: 16 * 1024 * 1024, timeout: 30000 }));
  requireThat(Array.isArray(pages) && pages.every(Array.isArray), "invalid GitHub response; approval unverified");
  return pages.flat();
}

async function waitForApproval(context, candidates, approvers) {
  // This internal timeout only bounds waiting; zero still requires a valid
  // authenticated approval. No environment variable can authorize publication.
  const seconds = Number(process.env.STABLE_APPROVAL_WAIT_SECONDS ?? 2700);
  requireThat(Number.isFinite(seconds) && seconds >= 0 && seconds <= 2700, "approval wait must be between zero and 2700 seconds");
  const deadline = Date.now() + seconds * 1000;
  console.log("Waiting up to 45 minutes for explicit approval on the exact merged release PR; no package is published.");
  let announced = false;
  do {
    const pulls = githubPages(`repos/${context.repository}/commits/${context.source_sha}/pulls?per_page=100`);
    const matching = pulls.filter(pull => pull.merged_at && pull.merge_commit_sha === context.source_sha && pull.base?.ref === "main" && pull.base?.repo?.full_name === context.repository);
    requireThat(matching.length <= 1, "ambiguous release PR for source SHA");
    if (matching.length === 1) {
      const pull = matching[0];
      if (!announced) { console.log(`Approval PR: https://github.com/${context.repository}/pull/${pull.number}`); announced = true; }
      const comments = githubPages(`repos/${context.repository}/issues/${pull.number}/comments?per_page=100`);
      for (const comment of comments.toReversed()) {
        if (comment.user?.type !== "User" || !approvers.includes(comment.user.login?.toLowerCase())) continue;
        const match = comment.body?.match(/^APPROVE STABLE PUBLICATION\r?\n```json\r?\n([\s\S]+?)\r?\n```\s*$/);
        if (!match) continue;
        let receipt;
        try { receipt = JSON.parse(match[1]); } catch { continue; }
        // Historical approvals cannot authorize a different run or retry.
        if (receipt.run_id !== context.run_id || receipt.run_attempt !== context.run_attempt) continue;
        receipt = validateApproval(comment, pull, approvers, context, candidates);
        return { receipt, author: comment.user.login, url: `https://github.com/${context.repository}/pull/${pull.number}#issuecomment-${comment.id}` };
      }
    }
    if (Date.now() >= deadline) break;
    await new Promise(resolve => setTimeout(resolve, Math.min(30000, deadline - Date.now())));
  } while (Date.now() <= deadline);
  throw new Error("Approval wait expired; retain the built artifacts, rerun failed jobs, and approve the new run attempt shown in its summary");
}

function writeApprovalTemplate(context, candidates) {
  const template = { schema: "egregore-stable-production/v1", ...context,
    verified_at: "", expires_at: "",
    deployment: { id: "", service: "", source_sha: "", image_digest: "", status: "not_verified", evidence_url: "", compatibility_evidence_url: "" },
    checks: Object.fromEntries(["old_client", "new_client", "cohort", "public_sources"].map(name => [name, { status: "not_verified", evidence_url: "" }])),
    packages: candidates };
  const summary = "## Stable publication awaits explicit approval\nComplete the production evidence below only after verification. An authorized human must approve this exact receipt on the merged release PR. This template is not an approval.\n\nAPPROVE STABLE PUBLICATION\n```json\n" + JSON.stringify(template, null, 2) + "\n```\n";
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
}

export function validateReceipt(receipt, context, candidates, now = Date.now()) {
  requireThat(receipt.schema === "egregore-stable-production/v1", "unsupported or missing production receipt");
  for (const field of ["repository", "source_sha", "run_id", "run_attempt"]) {
    requireThat(receipt[field] === context[field], `production receipt ${field} mismatch`);
  }
  requireThat(sha.test(receipt.source_sha), "invalid package source SHA");
  const verified = Date.parse(receipt.verified_at);
  const expires = Date.parse(receipt.expires_at);
  requireThat(Number.isFinite(verified) && Number.isFinite(expires) && verified <= now && now < expires && expires - verified <= 48 * 60 * 60 * 1000, "production receipt expired, future-dated, or valid for more than 48 hours");
  const deployment = receipt.deployment;
  requireThat(deployment?.status === "success" && typeof deployment.id === "string" && deployment.id.length > 0 && typeof deployment.service === "string" && deployment.service.length > 0 && sha.test(deployment.source_sha), "successful identified production deployment required");
  requireThat(/^sha256:[a-f0-9]{64}$/.test(deployment.image_digest || ""), "identified production image digest required");
  evidence(deployment.evidence_url, "deployment");
  // Different backend/client commits are permitted only with an explicit reviewed mapping.
  evidence(deployment.compatibility_evidence_url, "backend/client compatibility mapping");
  for (const name of ["old_client", "new_client", "cohort", "public_sources"]) {
    requireThat(receipt.checks?.[name]?.status === "passed", `${name}: passed production verification required`);
    evidence(receipt.checks[name].evidence_url, name);
  }
  requireThat(Array.isArray(receipt.packages) && receipt.packages.length === candidates.length, "receipt must cover exactly the selected package artifacts");
  requireThat(new Set(receipt.packages.map(p => p.name)).size === candidates.length, "duplicate receipt package");
  for (const candidate of candidates) {
    validateVersion(candidate.version);
    const accepted = receipt.packages.find(p => p.name === candidate.name);
    requireThat(accepted?.version === candidate.version && accepted?.sha256 === candidate.sha256, `unverified archive: ${candidate.name}`);
  }
}

async function main() {
  if (process.argv[2] === "--version") {
    validateVersion(process.argv[3]);
    return;
  }
  if (process.argv[2] === "--select") {
    const [, root, catalog, requested] = process.argv.slice(2);
    console.log(JSON.stringify(selectPublicationIntent(root, JSON.parse(catalog), requested)));
    return;
  }
  const preflight = process.argv[2] === "--preflight";
  const templateOnly = process.argv[2] === "--approval-template";
  const [directory] = process.argv.slice(preflight || templateOnly ? 3 : 2);
  requireThat(directory, "usage: validate-stable-publication.mjs [--preflight] ARTIFACT_DIRECTORY");
  const context = {
    repository: process.env.GITHUB_REPOSITORY,
    source_sha: process.env.SOURCE_SHA,
    run_id: process.env.GITHUB_RUN_ID,
    run_attempt: process.env.GITHUB_RUN_ATTEMPT,
  };
  requireThat(process.env.GITHUB_REF === "refs/heads/main", "stable verification must run on main");
  const packages = JSON.parse(process.env.SELECTED_PACKAGES || "[]");
  const intent = JSON.parse(process.env.PUBLISH_INTENT || "[]");
  validateSelectedIntent(packages, intent);
  const catalog = JSON.parse(execFileSync(process.execPath, [new URL("capability-distribution.mjs", import.meta.url).pathname,
    "release-packages", "--root", new URL("../", import.meta.url).pathname, "--json"], { encoding: "utf8" }));
  const artifactAttempt = process.env.ARTIFACT_ATTEMPT || context.run_attempt;
  requireThat(/^[1-9]\d*$/.test(artifactAttempt), "invalid artifact build attempt");
  const candidates = packages.map(name => {
    requireThat(catalog.includes(name), "unknown release package");
    const root = path.join(directory, `npm-${name}-${artifactAttempt}`);
    const metadata = JSON.parse(fs.readFileSync(path.join(root, "candidate.json"), "utf8"));
    requireThat(metadata.name === name && metadata.source_sha === context.source_sha && metadata.channel === "stable-recovery" && metadata.dist_tag === "latest", "candidate metadata does not match stable context");
    const files = fs.readdirSync(root).filter(file => file.endsWith(".tgz"));
    requireThat(files.length === 1, "exactly one archive per package required");
    const archive = path.join(root, files[0]);
    const manifest = JSON.parse(execFileSync("tar", ["-xOf", archive, "package/package.json"], { encoding: "utf8", maxBuffer: 1024 * 1024 }));
    requireThat(manifest.name === name && manifest.version === metadata.version, "archive and metadata identity mismatch");
    requireThat(intent.find(p => p.name === name)?.version === manifest.version, "archive differs from frozen publication intent");
    if (preflight) {
      const latest = registryView(`${name}@latest`, "version");
      const existing = registryView(`${name}@${manifest.version}`, null, true);
      validateRegistryCandidate(manifest, latest, existing, fs.readFileSync(archive));
    }
    return { name, version: manifest.version, sha256: crypto.createHash("sha256").update(fs.readFileSync(archive)).digest("hex") };
  });
  if (preflight) {
    console.log("All selected archives passed registry preflight. No packages were published; privileged checks still run after approval.");
    return;
  }
  const config = JSON.parse(fs.readFileSync(new URL("../egregore.json", import.meta.url), "utf8"));
  const approvers = releaseApprovers(config);
  if (templateOnly) { writeApprovalTemplate(context, candidates); return; }
  const { receipt, author, url } = await waitForApproval(context, candidates, approvers);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, `\nApproved by ${author}: ${url}\n`);
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `verified_run_attempt=${context.run_attempt}\nexpires_at=${receipt.expires_at}\npackages=${JSON.stringify(candidates)}\n`);
  }
  console.log("Stable production receipt verified for the exact source and package archives.");
}
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)) {
  try { await main(); } catch (error) {
    console.error(`Stable publication blocked: ${error.message}`);
    process.exitCode = 1;
  }
}
