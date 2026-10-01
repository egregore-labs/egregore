#!/usr/bin/env node
"use strict";

// Linked-worktree compatibility bridge for Codex UserPromptSubmit.
//
// Codex currently discovers project hooks from the primary checkout for a
// linked Git worktree, then executes the configured command in the linked
// worktree. Older Egregore primary checkouts therefore invoke this historical
// filename. Keep it as a thin bridge into the same harness-neutral Observe
// adapter used by current .codex/hooks.json; never implement retrieval here.

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function readStdin() {
  try { return fs.readFileSync(0, "utf-8"); } catch { return ""; }
}

const input = readStdin();
if (!input) process.exit(0);

const root = process.env.EGREGORE_ROOT || process.env.CLAUDE_PROJECT_DIR || process.cwd();
const adapter = path.join(root, "bin", "observe-context.sh");
if (!fs.existsSync(adapter)) process.exit(0);

const result = spawnSync("bash", [adapter, "codex"], {
  cwd: root,
  env: { ...process.env, EGREGORE_ROOT: root },
  input,
  encoding: "utf-8",
  timeout: 45_000,
});

if (result.stdout) process.stdout.write(result.stdout);
process.exit(0);
