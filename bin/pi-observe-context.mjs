import { spawn } from "node:child_process";
import { join } from "node:path";
import { createHash, randomUUID } from "node:crypto";

const DEFAULT_TIMEOUT_MS = 45_000;

function contextFromEnvelope(stdout) {
  const rendered = String(stdout || "").trim();
  if (!rendered) return "";
  const payload = JSON.parse(rendered);
  return String(payload?.hookSpecificOutput?.additionalContext || "").trim();
}

/**
 * Enter the runtime-neutral Observe boundary without putting the user's prompt
 * in argv, an environment variable, or a temporary file. The prompt is sent
 * only over the child process stdin expected by bin/observe-context.sh.
 */
export function compileObserveContext({ root, harness, prompt, sessionId, promptId, signal, timeoutMs } = {}) {
  const projectRoot = String(root || process.cwd());
  const runtime = String(harness || "pi");
  const input = JSON.stringify({ prompt: String(prompt || ""),
    ...(sessionId ? { session_id: sessionId, prompt_id: promptId || randomUUID() } : {}),
  }) + "\n";
  const configuredTimeout = Number(
    timeoutMs || process.env.EGREGORE_OBSERVE_TIMEOUT_MS || DEFAULT_TIMEOUT_MS,
  );
  const timeout = Number.isFinite(configuredTimeout) && configuredTimeout > 0
    ? configuredTimeout
    : DEFAULT_TIMEOUT_MS;

  return new Promise((resolve) => {
    const child = spawn("bash", [join(projectRoot, "bin", "observe-context.sh"), runtime], {
      cwd: projectRoot,
      env: {
        ...process.env,
        CLAUDE_PROJECT_DIR: projectRoot,
        EGREGORE_ROOT: projectRoot,
        EGREGORE_RUNTIME: runtime,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let settled = false;
    let timer;
    const finish = (value = "") => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener?.("abort", abort);
      resolve(value);
    };
    const abort = () => {
      try { child.kill("SIGTERM"); } catch {}
      finish("");
    };
    timer = setTimeout(abort, timeout);
    signal?.addEventListener?.("abort", abort, { once: true });
    if (signal?.aborted) return abort();
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.resume();
    child.on("error", () => finish(""));
    child.on("close", (code) => {
      if (code !== 0) return finish("");
      try { finish(contextFromEnvelope(stdout)); } catch { finish(""); }
    });
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

function bindNativeSession(ctx, harness) {
  const session = sessionIdentity(ctx);
  if (session) {
    process.env.EGREGORE_NATIVE_SESSION_ID = session;
    process.env.EGREGORE_NATIVE_HARNESS = String(harness || "pi");
  } else {
    delete process.env.EGREGORE_NATIVE_SESSION_ID;
    delete process.env.EGREGORE_NATIVE_HARNESS;
  }
  return session;
}

function sessionIdentity(ctx) {
  const file = ctx?.sessionManager?.getSessionFile?.();
  return file ? createHash("sha256").update(String(file)).digest("hex") : undefined;
}

/** Register the real per-prompt extension boundary shared by Pi and Prime. */
export function registerUserCommand(pi, { root, harness }, name, command) {
  pi.registerCommand(name, {
    ...command,
    handler: async (args, ctx) => {
      // Native commands bypass before_agent_start's Observe hook while their
      // workflow is active. Reset at the actual user entry, before dispatch;
      // generated workflow turns must not reset same-prompt limits.
      const context = await compileObserveContext({ root, harness, prompt: "", sessionId: bindNativeSession(ctx, harness), signal: ctx?.signal });
      if (context) pi.sendMessage?.({ customType: "egregore-org-context", content: context, display: false });
      return command.handler(args, ctx);
    },
  });
}

/** Register the model-prompt boundary; native commands reset at entry above. */
export function registerObserveHook(pi, { root, harness, shouldObserve } = {}) {
  pi.on("before_agent_start", async (event, ctx) => {
    if (shouldObserve && !shouldObserve(event, ctx)) return;
    const context = await compileObserveContext({
      root,
      harness,
      prompt: event.prompt,
      sessionId: bindNativeSession(ctx, harness),
      signal: ctx?.signal,
    });
    if (!context) return;
    return {
      message: {
        customType: "egregore-org-context",
        content: context,
        display: false,
        details: {
          source: "EgregoreRuntime.observe",
          harness: String(harness || "pi"),
        },
      },
    };
  });
}
