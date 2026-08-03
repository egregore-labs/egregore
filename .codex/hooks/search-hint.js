#!/usr/bin/env node
"use strict";
// search-hint.js — UserPromptSubmit hook (Codex runtime).
//
// Mirror of .claude/hooks/search-hint.sh: when the user's prompt is
// recall-shaped ("find the handoff about…", "did we decide…"), inject a
// routing hint toward `bash bin/search.sh query` — one ranked call over
// memory/ — instead of improvised ls/grep/graph exploration.
//
// Advisory only, never blocks, rate-limited once per session, exits 0.
// If the Codex runtime does not fire UserPromptSubmit, this file is inert.

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

function readStdin() {
  try { return fs.readFileSync(0, "utf-8"); } catch { return ""; }
}
function parseJson(raw) {
  try { return JSON.parse(raw || "{}"); } catch { return {}; }
}

const input = parseJson(readStdin());
const prompt = String(input.prompt || input.user_prompt || "");
if (!prompt) process.exit(0);

const root = process.env.CLAUDE_PROJECT_DIR || process.cwd();
if (!fs.existsSync(path.join(root, "bin", "search.sh"))) process.exit(0);

// Already oriented toward search.
if (/(\/search\b|search\.sh|\bsearch (the )?memory\b)/i.test(prompt)) process.exit(0);

const RECALL = new RegExp(
  [
    "\\b(find|locate|dig up|look up|pull up)\\b.*\\b(handoff|decision|notes?|docs?|meeting|harvest|quest|reflection)s?\\b",
    "\\bdid we (decide|discuss|agree|say|talk about|cover)\\b",
    "\\bdo we have (any )?(notes?|docs?|anything|something)( on| about)?\\b",
    "\\bwhat did we (decide|say|agree|discuss)\\b",
    "\\bhave we (discussed|decided|covered|talked about|looked at)\\b",
    "\\bnotes on\\b",
    "\\bhandoff (from|about)\\b",
    "\\bwho worked on\\b",
    "\\bdidn.?t (someone|we) already\\b",
    "\\bwas there (a|any) (handoff|decision|discussion|meeting)\\b",
    "\\b(our|company|org|organization|team)\\b.*\\b(pricing|price|tiers?|plans?|paid|free|strategy|policy|positioning|ownership|decision)\\b",
    "\\b(pricing|price|tiers?|plans?|paid|free)\\b.*\\b(our|company|org|organization|team)\\b",
  ].join("|"),
  "i"
);
if (!RECALL.test(prompt)) process.exit(0);

// Rate-limit once per session.
let sid = "default";
try { sid = fs.readFileSync(path.join(root, ".egregore-session-id"), "utf-8").trim() || "default"; } catch {}
const flag = path.join(os.tmpdir(), `egregore-search-hint-${sid}`);
if (fs.existsSync(flag)) process.exit(0);
try { fs.writeFileSync(flag, "1"); } catch {}

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext:
      "Routing hint: this prompt asks for recall from org memory. FIRST action: `bash bin/search.sh query \"<the concept, not the literal sentence>\"` — one ranked call over all of memory/ (hybrid keyword+semantic; graph-state annotations attach automatically in connected mode). Read the top hits and cite paths. Do NOT improvise ls/grep/graph exploration first — hand-written graph queries against invented labels (e.g. :Handoff — handoffs are :Session nodes) return empty. Full spec: the search skill.",
  },
}) + "\n");
process.exit(0);
