import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { isConsentCommand, isMutatingBash, isRuntimeStatePath, mutatesOnlyRuntimeState } from "../../bin/pi-branch-policy.mjs";
import {
  activityDataPath,
  captureSessionEnd,
  createHandoff,
  lastActivityJson,
  parseViewRequest,
  publishScroll,
  renderActivity,
  renderGreeting,
  renderView,
  workflowPrompt,
} from "../../bin/pi-product-workflows.mjs";

const PROTECTED_BRANCHES = new Set(["main", "master", "develop"]);
const BUILTIN_COMMANDS = new Set([
  "login", "logout", "model", "settings", "resume", "new", "name",
  "session", "tree", "trust", "fork", "clone", "compact", "copy",
  "export", "import", "share", "reload", "hotkeys", "changelog", "quit",
]);
const PRODUCT_COMMANDS = new Set(["activity", "view", "handoff", "scroll"]);

function skillDescription(skillFile) {
  try {
    const body = readFileSync(skillFile, "utf8");
    return body.match(/^description:\s*['"]?(.+?)['"]?\s*$/m)?.[1] || "Run an Egregore workflow";
  } catch {
    return "Run an Egregore workflow";
  }
}

function messageText(result) {
  return (result?.content || [])
    .filter((item) => item?.type === "text")
    .map((item) => item.text)
    .join("\n");
}

function compactToolResult(result, options, theme, working) {
  if (options.isPartial) return new Text(theme.fg("muted", working), 0, 0);
  const text = result?.details?.text || messageText(result) || "Done";
  return new Text(result?.details?.text ? text : theme.fg("error", text), 0, 0);
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function nearestExistingDirectory(candidate) {
  let cursor = resolve(candidate);
  try {
    if (existsSync(cursor) && !statSync(cursor).isDirectory()) cursor = dirname(cursor);
  } catch {}
  while (!existsSync(cursor)) {
    const parent = dirname(cursor);
    if (parent === cursor) break;
    cursor = parent;
  }
  return cursor;
}

async function gitContext(pi, candidate) {
  const probe = nearestExistingDirectory(candidate);
  const topResult = await pi.exec("git", ["-C", probe, "rev-parse", "--show-toplevel"], { timeout: 5000 });
  const top = String(topResult.stdout || "").trim();
  if (!top) return null;
  const commonResult = await pi.exec("git", ["-C", top, "rev-parse", "--git-common-dir"], { timeout: 5000 });
  const commonRaw = String(commonResult.stdout || "").trim();
  return {
    top: resolve(top),
    common: resolve(top, commonRaw || ".git"),
  };
}

export default function egregore(pi) {
  const root = process.cwd();
  const skillsDir = join(root, ".codex", "skills");
  let workflowCount = 0;
  let lastSyncAt = 0;
  let activeWorkflow = "";
  const hasEntryRenderer = typeof pi.registerEntryRenderer === "function";

  const appendCard = (kind, text) => {
    const content = String(text || "").trimEnd();
    if (hasEntryRenderer) {
      pi.appendEntry("egregore-card", { kind, text: content });
      return;
    }
    pi.sendMessage({
      customType: "egregore-card",
      content,
      display: true,
      details: { kind },
    }, { triggerTurn: false });
  };

  const setBusy = (ctx, label) => {
    if (!ctx.hasUI) return;
    ctx.ui.setStatus("egregore-workflow", label ? `● ${label}` : undefined);
  };

  const sendQuietWorkflow = (name, args, ctx, options = {}) => {
    activeWorkflow = name;
    if (ctx.hasUI) {
      ctx.ui.setToolsExpanded?.(false);
      ctx.ui.setWorkingMessage?.(options.working || `Running /${name}…`);
    }
    const content = options.prompt || workflowPrompt(name, args, options.extra || "");
    if (typeof pi.sendMessage === "function") {
      pi.sendMessage({
        customType: "egregore-workflow",
        content,
        display: false,
        details: { command: name },
      }, { triggerTurn: true, deliverAs: "steer" });
    } else {
      pi.sendUserMessage(content);
    }
  };

  if (hasEntryRenderer) {
    pi.registerEntryRenderer("egregore-card", (entry) => {
      return new Text(String(entry.data?.text || ""), 0, 0);
    });
  } else if (typeof pi.registerMessageRenderer === "function") {
    pi.registerMessageRenderer("egregore-card", (message) => {
      return new Text(String(message.content || ""), 0, 0);
    });
  }

  pi.registerTool({
    name: "egregore_handoff",
    label: "Egregore Handoff",
    description: "Create one internal Egregore team handoff from structured session context. Use only for the /handoff workflow.",
    parameters: Type.Object({
      topic: Type.String({ description: "Short operational topic" }),
      recipient: Type.Optional(Type.String({ description: "Known teammate handle; omit when uncertain" })),
      briefing: Type.String({ description: "Concise operational briefing" }),
      key_decisions: Type.String({ description: "Markdown bullets of settled decisions" }),
      current_state: Type.String({ description: "Exact implementation and verification state" }),
      open_threads: Type.String({ description: "Markdown bullets of unresolved work" }),
      next_steps: Type.String({ description: "Ordered, actionable next steps" }),
      entry_points: Type.String({ description: "Exact files, branches, commands, and URLs" }),
    }),
    async execute(_toolCallId, params, signal) {
      const receipt = await createHandoff(pi, root, params, signal);
      return {
        content: [{ type: "text", text: `Handoff created${receipt.path ? ` at ${receipt.path}` : ""}.` }],
        details: { ...receipt },
      };
    },
    renderCall(_args, theme) {
      return new Text(theme.fg("muted", "⇌ Preparing handoff…"), 0, 0);
    },
    renderResult(result, options, theme) {
      return compactToolResult(result, options, theme, "⇌ Preparing handoff…");
    },
  });

  pi.registerTool({
    name: "egregore_publish_scroll",
    label: "Publish Egregore Scroll",
    description: "Validate, publish, open, and receipt a completed Egregore scroll. Use only as the final action of /scroll.",
    parameters: Type.Object({
      source: Type.String({ description: "Project-relative tmp/<slug>/index.html source" }),
      slug: Type.String({ description: "Stable scroll id reused across versions" }),
      title: Type.String(),
      author: Type.String(),
      description: Type.String(),
      version: Type.String({ description: "Version marker such as v1" }),
    }),
    async execute(_toolCallId, params, signal) {
      const receipt = await publishScroll(pi, root, params, signal);
      return {
        content: [{ type: "text", text: `Scroll ${receipt.version} opened at ${receipt.url || receipt.path}.` }],
        details: { ...receipt },
      };
    },
    renderCall(_args, theme) {
      return new Text(theme.fg("muted", "◉ Publishing scroll…"), 0, 0);
    },
    renderResult(result, options, theme) {
      return compactToolResult(result, options, theme, "◉ Publishing scroll…");
    },
  });

  if (existsSync(skillsDir)) {
    for (const entry of readdirSync(skillsDir, { withFileTypes: true })) {
      if (!entry.isDirectory() || BUILTIN_COMMANDS.has(entry.name)) continue;
      const skillFile = join(skillsDir, entry.name, "SKILL.md");
      if (!existsSync(skillFile)) continue;
      workflowCount += 1;
      if (PRODUCT_COMMANDS.has(entry.name)) continue;
      pi.registerCommand(entry.name, {
        description: skillDescription(skillFile),
        handler: async (args, ctx) => sendQuietWorkflow(entry.name, args, ctx),
      });
    }
  }

  pi.registerCommand("activity", {
    description: skillDescription(join(skillsDir, "activity", "SKILL.md")),
    handler: async (_args, ctx) => {
      setBusy(ctx, "Refreshing activity");
      try {
        const shouldSync = Date.now() - lastSyncAt > 60_000;
        const card = await renderActivity(pi, root, ctx.signal, { sync: shouldSync });
        lastSyncAt = Date.now();
        appendCard("activity", card);
      } catch (error) {
        ctx.ui.notify(`Activity: ${errorMessage(error)}`, "error");
        return;
      } finally {
        setBusy(ctx, "");
      }

      if (!ctx.hasUI) return;
      const focus = await ctx.ui.select("Focus", ["Handoffs", "Questions", "Recent work", "Dashboard", "Done"]);
      if (!focus || focus === "Done") return;
      const command = focus === "Dashboard" ? "dashboard" : "activity";
      // Hand the model the complete data the extension already fetched, as a
      // file: one fast read, never truncated, no reason to re-run the data
      // script or spelunk renderer sources.
      const cached = lastActivityJson();
      const prompt = focus === "Dashboard"
        ? workflowPrompt("dashboard", "")
        : [
          `Continue the Egregore /activity workflow with focus: ${focus.toLowerCase()}.`,
          "Output nothing except the final rendered result — no prose, planning, or narration between commands.",
          cached
            ? `The complete activity data is already fresh at ${relative(root, activityDataPath(root))} — read that file in one call; do NOT re-run bin/activity-data.sh, read renderer sources, or run other data commands.`
            : "",
          "If required data is missing or a command fails, render the single line '◦ activity data unavailable' and stop — never debug data plumbing inside this workflow.",
          "Rows without a topic: show the branch name instead; with neither, omit the row — never print (untitled).",
        ].filter(Boolean).join("\n");
      sendQuietWorkflow(command, "", ctx, { prompt, working: `Opening ${focus.toLowerCase()}…` });
    },
  });

  pi.registerCommand("view", {
    description: skillDescription(join(skillsDir, "view", "SKILL.md")),
    handler: async (args, ctx) => {
      let request = parseViewRequest(root, args);
      if (request.kind === "choose" && ctx.hasUI) {
        const choice = await ctx.ui.select("Open a view", ["Activity", "Board", "Network", "Document or topic…"]);
        if (!choice) return;
        if (choice === "Document or topic…") {
          const target = await ctx.ui.input("Document or topic", "path, handoff, quest, or subject");
          if (!target) return;
          request = parseViewRequest(root, target);
        } else {
          request = parseViewRequest(root, choice.toLowerCase());
        }
      }

      if (request.kind === "choose-file" && ctx.hasUI) {
        const labels = request.matches.map((file) => relative(root, file));
        const selected = await ctx.ui.select("Choose a source", labels);
        if (!selected) return;
        request = { kind: "native", type: request.type, source: join(root, selected), fast: request.fast };
      }

      if (request.kind !== "native") {
        sendQuietWorkflow("view", args, ctx, {
          working: "Composing view…",
          extra: "Open the browser artifact and return only the compact receipt required by the skill.",
        });
        return;
      }

      setBusy(ctx, "Opening view");
      try {
        const receipt = await renderView(pi, root, request, ctx.signal);
        appendCard("view", receipt.text);
      } catch (error) {
        ctx.ui.notify(`View: ${errorMessage(error)}`, "error");
      } finally {
        setBusy(ctx, "");
      }
    },
  });

  pi.registerCommand("handoff", {
    description: skillDescription(join(skillsDir, "handoff", "SKILL.md")),
    handler: async (args, ctx) => {
      const people = existsSync(join(root, "memory", "people"))
        ? readdirSync(join(root, "memory", "people"))
          .filter((name) => name.endsWith(".md") && name !== "README.md")
          .map((name) => name.replace(/\.md$/, ""))
          .slice(0, 40)
        : [];
      const prompt = [
        "Create the requested internal Egregore handoff from the current conversation and repository context.",
        "Call egregore_handoff exactly once. Do not call bash, write, edit, or read the handoff skill; the tool implements the full contract.",
        "Keep every field concise and operational. Include exact files, branch, commands, open questions, and verification state.",
        "Omit recipient when uncertain. Do not use the deprecated egregore-handoff CLI.",
        args?.trim() ? `User arguments: ${args.trim()}` : "Infer the topic and intended recipient from the conversation.",
        people.length ? `Known teammate handles: ${people.join(", ")}` : "",
        "After the tool succeeds, do not repeat its card or add a success preamble.",
      ].filter(Boolean).join("\n");
      sendQuietWorkflow("handoff", args, ctx, { prompt, working: "Preparing handoff…" });
    },
  });

  pi.registerCommand("scroll", {
    description: skillDescription(join(skillsDir, "scroll", "SKILL.md")),
    handler: async (args, ctx) => {
      sendQuietWorkflow("scroll", args, ctx, {
        working: "Composing scroll…",
        extra: [
          "Use egregore_publish_scroll exactly once as the final validation, publish, open, and receipt step.",
          "Do not run publish-artifact.sh or a browser opener directly.",
          "Return only what changed, the stable URL or local path, the source path, and the versioned decision fence.",
        ].join("\n"),
      });
    },
  });

  pi.on("session_start", async (event, ctx) => {
    if (!ctx.hasUI) return;
    ctx.ui.setToolsExpanded?.(false);
    if (workflowCount > 0) ctx.ui.setStatus("egregore", `Egregore · ${workflowCount} workflows`);
    if (event.reason !== "startup") return;

    setBusy(ctx, "Loading team context");
    try {
      const card = await renderGreeting(pi, root, ctx.signal);
      lastSyncAt = Date.now();
      appendCard("greeting", card);
    } catch (error) {
      ctx.ui.notify(`Startup: ${errorMessage(error)}`, "warning");
    } finally {
      setBusy(ctx, "");
    }
  });

  pi.on("session_shutdown", async (event, ctx) => {
    // Reload keeps the same logical session alive. Every other graceful
    // shutdown is Pi's equivalent of Claude Code's SessionEnd hook.
    if (event?.reason === "reload") return;
    try {
      await captureSessionEnd(pi, root, ctx.sessionManager.getSessionFile(), undefined);
    } catch {
      // Loss-prevention capture must never prevent Pi from exiting. The
      // attendant remains the fallback for interrupted or failed shutdowns.
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (!activeWorkflow || !ctx.hasUI) return;
    activeWorkflow = "";
    ctx.ui.setWorkingMessage?.();
    ctx.ui.setToolsExpanded?.(false);
  });

  pi.on("tool_call", async (event, ctx) => {
    const isFileWrite = event.toolName === "write" || event.toolName === "edit";
    const command = String(event.input?.command || "");
    const mutates = isFileWrite || (event.toolName === "bash" && isMutatingBash(command));
    if (!mutates) return;

    // Resolve the branch in the git context the write actually lands in.
    // Task worktrees from `bin/agent.sh branch` live outside ctx.cwd but sit
    // on a task branch, so checking ctx.cwd alone blocks legitimate worktree
    // edits whenever the session checkout itself is on develop. Memory and
    // managed repos have a different Git common dir and are outside this guard.
    const hub = await gitContext(pi, ctx.cwd);
    if (event.toolName === "bash" && mutatesOnlyRuntimeState(command, hub?.top || ctx.cwd)) return;
    let operation = hub;
    if (isFileWrite) {
      const targetPath = String(event.input?.path || "");
      const abs = isAbsolute(targetPath) ? targetPath : join(ctx.cwd, targetPath);
      if (hub && isRuntimeStatePath(abs, hub.top)) return;
      operation = await gitContext(pi, abs);
      if (!operation && hub) {
        const rel = relative(hub.top, abs);
        if (rel.startsWith("..") || isAbsolute(rel)) return;
      }
    } else {
      // bash: `git -C PATH` or a leading `cd DIR &&` retargets the command
      // away from ctx.cwd — resolve the branch where it actually runs so
      // worktree commits (git -C $WT commit) aren't misjudged by the session
      // checkout's branch.
      const gitC = command.match(/(?:^|[;&|]\s*)git\s+-C\s+("[^"]*"|'[^']*'|\S+)/);
      const cdAnd = command.match(/^\s*cd\s+("[^"]*"|'[^']*'|\S+)\s*&&/);
      const raw = (gitC && gitC[1]) || (cdAnd && cdAnd[1]);
      if (raw) {
        const target = raw.replace(/^['"]|['"]$/g, "");
        const abs = isAbsolute(target) ? target : join(ctx.cwd, target);
        operation = await gitContext(pi, abs);
      }
    }

    if (hub && operation && operation.common !== hub.common) return;
    const gitDir = operation?.top || hub?.top || ctx.cwd;
    const result = await pi.exec("git", ["-C", gitDir, "branch", "--show-current"], { timeout: 5000 });
    const branch = String(result.stdout || "").trim();
    let configuredBase = "develop";
    try {
      const config = JSON.parse(readFileSync(join(gitDir, "egregore.json"), "utf8"));
      if (typeof config.base_branch === "string" && config.base_branch.trim()) {
        configuredBase = config.base_branch.trim();
      }
    } catch {}
    if (!PROTECTED_BRANCHES.has(branch) && branch !== configuredBase) return;

    // The documented escape hatch must itself be runnable: recording consent
    // (echo 'develop' into .egregore-branch-consent) contains a redirect and
    // would otherwise be blocked by this very gate.
    if (event.toolName === "bash") {
      if (isConsentCommand(String(event.input?.command || "").trim(), branch)) return;
    }

    const consentFile = join(gitDir, ".egregore-branch-consent");
    if (existsSync(consentFile) && readFileSync(consentFile, "utf8").trim() === branch) return;

    return {
      block: true,
      reason: [
        `Protected branch (${branch}). Move project work to a task branch before writing.`,
        `If the work topic is clear, run bin/agent.sh branch --topic "<work topic>" automatically and continue in the printed worktree; do not ask for routine Git permission.`,
        `Ask only when the topic is genuinely ambiguous.`,
        `Only when the user explicitly requested ${branch}, record consent with: echo '${branch}' > .egregore-branch-consent`,
        "Memory, managed-repo, and runtime-state writes should bypass this project guard.",
      ].join("\n"),
    };
  });
}
