#!/usr/bin/env node

import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, relative, resolve } from "node:path";

const ANSI = /\x1b\[[0-?]*[ -/]*[@-~]/g;

function resultCode(result) {
  return Number(result?.code ?? result?.status ?? 0);
}

function commandFailure(label, result) {
  const detail = String(result?.stderr || result?.stdout || "").replace(ANSI, "").trim();
  return new Error(detail ? `${label}: ${detail}` : `${label} failed`);
}

async function checkedExec(pi, command, args, options = {}, label = command) {
  const result = await pi.exec(command, args, options);
  if (resultCode(result) !== 0) throw commandFailure(label, result);
  return String(result.stdout || "");
}

function readJson(file, fallback = {}) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function cleanArgs(value) {
  return String(value || "").trim();
}

function walkMarkdown(dir, files = []) {
  if (!existsSync(dir)) return files;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) walkMarkdown(full, files);
    else if (entry.isFile() && entry.name.endsWith(".md")) files.push(full);
  }
  return files;
}

function inferArtifactType(file) {
  const normalized = file.replaceAll("\\", "/");
  if (normalized.includes("/memory/quests/")) return "quest";
  if (normalized.includes("/memory/handoffs/")) return "handoff";
  return "document";
}

function matchingFiles(root, type, query) {
  const base = type === "quest"
    ? join(root, "memory", "quests")
    : type === "handoff"
      ? join(root, "memory", "handoffs")
      : join(root, "memory");
  const needle = query.toLowerCase().replace(/\.md$/, "");
  return walkMarkdown(base)
    .filter((file) => basename(file, ".md").toLowerCase().includes(needle))
    .sort((a, b) => b.localeCompare(a));
}

export function parseViewRequest(root, rawArgs) {
  const raw = cleanArgs(rawArgs);
  if (!raw) return { kind: "choose" };

  const fast = /(?:^|\s)--(?:fast|floor)(?:\s|$)/.test(raw);
  const compose = /(?:^|\s)--compose(?:\s|$)/.test(raw);
  const cleaned = raw.replace(/(?:^|\s)--(?:fast|floor|compose)(?=\s|$)/g, " ").trim();
  const surface = cleaned.toLowerCase();
  if (["activity", "board", "network"].includes(surface)) {
    return { kind: "native", type: surface, source: "", fast: true };
  }

  const explicit = cleaned.match(/^(quest|handoff|document)\s+(.+)$/i);
  const type = explicit?.[1]?.toLowerCase();
  const target = (explicit?.[2] || cleaned).replace(/^@/, "").trim();
  const direct = resolve(root, target);
  if (existsSync(direct)) {
    const inferred = type || inferArtifactType(direct);
    if (inferred === "document" && (!fast || compose)) {
      return { kind: "model", reason: "document-composition", raw };
    }
    return { kind: "native", type: inferred, source: direct, fast };
  }

  if (type) {
    const matches = matchingFiles(root, type, target);
    if (matches.length === 1 && (type !== "document" || fast)) {
      return { kind: "native", type, source: matches[0], fast };
    }
    if (matches.length > 1) return { kind: "choose-file", type, matches, fast };
  }

  return { kind: "model", reason: "resolve-or-synthesize", raw };
}

function rendererCommand(root) {
  const local = join(root, "packages", "egregore-artifacts", "bin", "cli.js");
  const react = join(root, "packages", "egregore-artifacts", "node_modules", "react");
  if (existsSync(local) && existsSync(react)) return { command: "node", prefix: [local] };
  return { command: "npx", prefix: ["-y", "egregore-artifacts@latest"] };
}

function artifactPath(output) {
  const clean = String(output || "").replace(ANSI, "");
  const matches = clean.match(/(?:\/[^\s'\"]+|[A-Za-z]:\\[^\r\n'\"]+)\.html/g);
  return matches?.at(-1) || "";
}

export async function renderView(pi, root, request, signal) {
  const renderer = rendererCommand(root);
  const args = [...renderer.prefix, request.type];
  if (request.source) args.push(request.source);
  const output = await checkedExec(
    pi,
    renderer.command,
    args,
    { signal, timeout: 120000 },
    "Artifact render",
  );
  const file = artifactPath(output);
  let text = "✓ Artifact opened in browser";
  if (file) text += `\n  File: ${file}`;

  if (request.type === "board") {
    const config = readJson(join(root, "egregore.json"));
    if (config.slug && config.mode !== "local" && config.api_url) {
      text += `\n◆ https://egregore.xyz/view/${config.slug}/board   (stable — refresh for latest)`;
    }
  }
  return { text, file, type: request.type };
}

export async function renderGreeting(pi, root, signal, startScript = "pi-session-start.sh") {
  const script = join(root, "bin", startScript);
  if (!existsSync(script)) throw new Error("Egregore startup renderer is missing");
  return checkedExec(pi, "bash", [script, "--card"], { signal, timeout: 45000 }, "Egregore startup");
}

// Raw JSON from the most recent activity-data.sh run, so follow-up focus
// turns can receive the data inline instead of re-running the script inside
// a harness surface that may cap command time (Prime's kernel kills execs at
// ~5s, truncating the 10-20s data script to a partial fragment).
let lastActivityData = "";
export function lastActivityJson() {
  return lastActivityData;
}

// Stable on-disk copy of the same data. Focus turns point the model at this
// path instead of an inline excerpt: a file read is one fast kernel call,
// never truncated, and removes any reason to re-run the data script.
export function activityDataPath(root) {
  return join(root, ".egregore", "activity-data.json");
}

function persistActivityData(root, json) {
  try {
    mkdirSync(join(root, ".egregore"), { recursive: true });
    writeFileSync(activityDataPath(root), json);
  } catch {
    // Cache only — rendering proceeds from memory when the disk write fails.
  }
}

export async function renderActivity(pi, root, signal, options = {}) {
  if (options.sync !== false) {
    await checkedExec(
      pi,
      "bash",
      [join(root, "bin", "agent.sh"), "sync"],
      { signal, timeout: 120000 },
      "Memory sync",
    );
  }

  const state = readJson(join(root, ".egregore-state.json"));
  let handle = state.github_username || state.name || "";
  if (!handle) {
    handle = (await checkedExec(
      pi,
      "git",
      ["-C", root, "config", "user.name"],
      { signal, timeout: 5000 },
      "Identity lookup",
    )).trim();
  }

  const json = await checkedExec(
    pi,
    "bash",
    [join(root, "bin", "activity-data.sh"), handle],
    { signal, timeout: 120000 },
    "Activity refresh",
  );
  lastActivityData = String(json || "");
  persistActivityData(root, lastActivityData);
  const temp = mkdtempSync(join(tmpdir(), "egregore-pi-activity-"));
  const input = join(temp, "activity.json");
  try {
    writeFileSync(input, json);
    return await checkedExec(
      pi,
      "node",
      [join(root, "bin", "codex-skill-render.mjs"), "activity-card", input],
      { signal, timeout: 10000 },
      "Activity render",
    );
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

function section(title, body) {
  const value = cleanArgs(body) || "- None recorded.";
  return `## ${title}\n\n${value}`;
}

export function buildHandoffDocument(params, author, date = new Date().toISOString().slice(0, 10)) {
  const topic = cleanArgs(params.topic);
  const recipient = cleanArgs(params.recipient);
  const lines = [
    "---",
    "capture_schema: egregore-capture/v1",
    "capture_mode: addressed",
    "kind: addressed",
    `from: ${author}`,
  ];
  if (recipient) lines.push(`addressed_to: ${recipient}`);
  lines.push(
    `date: ${date}`,
    `topic: ${topic}`,
    "intent: action",
    "---",
    "",
    `# Handoff: ${topic}`,
    "",
    section("Briefing", params.briefing),
    "",
    section("Key Decisions", params.key_decisions),
    "",
    section("Current State", params.current_state),
    "",
    section("Open Threads", params.open_threads),
    "",
    section("Next Steps", params.next_steps),
    "",
    section("Entry Points", params.entry_points),
    "",
  );
  return lines.join("\n");
}

export async function createHandoff(pi, root, params, signal) {
  const state = readJson(join(root, ".egregore-state.json"));
  const author = state.github_username || state.name || "egregore";
  const temp = mkdtempSync(join(tmpdir(), "egregore-pi-handoff-"));
  const body = join(temp, "handoff.md");
  const recipient = cleanArgs(params.recipient);
  const runnerArgs = [
    "--author", author,
    "--topic", cleanArgs(params.topic),
    "--content-mode", "supplied",
  ];
  if (recipient) runnerArgs.push("--recipient", recipient);
  writeFileSync(body, buildHandoffDocument(params, author));

  try {
    const shell = 'tmp="$1"; body="$2"; runner="$3"; shift 3; TMPDIR="$tmp" bash "$runner" --mode addressed "$@" < "$body"';
    await checkedExec(
      pi,
      "bash",
      ["-c", shell, "egregore-pi-handoff", temp, body, join(root, "bin", "capture-run.sh"), ...runnerArgs],
      { signal, timeout: 180000 },
      "Handoff",
    );
    const resultFile = join(temp, "handoff-run-result.json");
    if (!existsSync(resultFile)) throw new Error("Handoff completed without a result receipt");
    const result = readJson(resultFile);
    const card = await checkedExec(
      pi,
      "node",
      [join(root, "bin", "codex-skill-render.mjs"), "handoff-card", resultFile],
      { signal, timeout: 10000 },
      "Handoff receipt",
    );
    return {
      text: card.trim(),
      path: result.file ? `memory/${result.file}` : "",
      url: result.artifactUrl || "",
    };
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

export async function captureSessionEnd(pi, root, sessionFile, signal, runtime = "pi") {
  const sessionIdFile = join(root, ".egregore-session-id");
  if (!existsSync(sessionIdFile)) return false;
  const sessionId = cleanArgs(readFileSync(sessionIdFile, "utf8"));
  if (!sessionId) return false;

  const temp = mkdtempSync(join(tmpdir(), "egregore-pi-session-end-"));
  const input = join(temp, "session-end.json");
  writeFileSync(input, JSON.stringify({
    session_id: sessionId,
    transcript_path: cleanArgs(sessionFile),
    runtime,
  }));

  try {
    const shell = 'bash "$1" < "$2"';
    await checkedExec(
      pi,
      "bash",
      ["-c", shell, "egregore-pi-session-end", join(root, "bin", "session-log.sh"), input],
      { signal, timeout: 10000 },
      "Session capture",
    );
    return true;
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
}

export async function publishScroll(pi, root, params, signal) {
  const source = resolve(root, String(params.source || "").replace(/^@/, ""));
  if (!existsSync(source)) throw new Error(`Scroll source not found: ${relative(root, source)}`);
  const html = readFileSync(source, "utf8");
  if (/__[A-Z][A-Z0-9_]*__/.test(html)) throw new Error("Scroll still contains unresolved placeholders");

  const config = readJson(join(root, "egregore.json"));
  let url = "";
  if (config.mode !== "local" && config.api_url) {
    const output = await checkedExec(
      pi,
      "bash",
      [
        join(root, "bin", "publish-artifact.sh"),
        "document",
        source,
        "--raw-html",
        "--id",
        cleanArgs(params.slug),
        "--title",
        cleanArgs(params.title),
        "--author",
        cleanArgs(params.author),
        "--description",
        cleanArgs(params.description),
      ],
      { signal, timeout: 180000 },
      "Scroll publish",
    );
    url = String(output).match(/https:\/\/[^\s]+/)?.[0] || "";
    if (!url) throw new Error("Scroll publish did not return a stable URL");
    const opener = process.platform === "darwin" ? "open" : "xdg-open";
    await checkedExec(pi, opener, [url], { signal, timeout: 10000 }, "Open scroll");
  } else {
    const opener = process.platform === "darwin" ? "open" : "xdg-open";
    await checkedExec(pi, opener, [source], { signal, timeout: 10000 }, "Open scroll");
  }

  const version = cleanArgs(params.version) || "v1";
  const destination = url || source;
  return {
    text: `✓ Scroll ${version} opened\n  ${url ? "URL" : "File"}: ${destination}`,
    path: source,
    url,
    version,
  };
}

export function workflowPrompt(name, args, extra = "", spec = { runtimeName: "Pi", specPath: ".pi/APPEND_SYSTEM.md" }) {
  const userArgs = cleanArgs(args);
  return [
    `Run the Egregore /${name} workflow now.`,
    `Read .codex/skills/${name}/SKILL.md completely and adapt Codex-specific wording to ${spec.runtimeName} using ${spec.specPath}.`,
    "Work quietly: do not narrate progress, expose raw command output, or repeat tool results.",
    "Use the fewest targeted reads and commands that preserve the workflow contract.",
    userArgs ? `User arguments: ${userArgs}` : "",
    extra,
  ].filter(Boolean).join("\n");
}
