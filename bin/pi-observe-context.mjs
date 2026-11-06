import { spawn } from "node:child_process";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { closeSync, constants, fchmodSync, fstatSync, lstatSync, mkdirSync, openSync, readSync, realpathSync, rmdirSync, writeSync } from "node:fs";

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

const ALIAS_LIMIT = 1024 * 1024;

function boundedFirstLine(path) {
  let descriptor;
  try {
    descriptor = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW);
    if (!fstatSync(descriptor).isFile()) return;
    const buffer = Buffer.alloc(ALIAS_LIMIT + 1);
    let size = 0;
    while (size <= ALIAS_LIMIT) {
      const count = readSync(descriptor, buffer, size, Math.min(4096, buffer.length - size), null);
      if (!count) return buffer.subarray(0, size).toString("utf8");
      const newline = buffer.indexOf(10, size);
      size += count;
      if (newline >= 0 && newline < size) return buffer.subarray(0, newline).toString("utf8");
    }
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}

function instanceRoot(root) {
  const physical = realpathSync(root || process.cwd());
  try {
    const line = boundedFirstLine(join(physical, ".git"));
    if (line?.startsWith("gitdir: ")) {
      const target = realpathSync(resolve(physical, line.slice(8).trim()));
      const marker = `${sep}.git${sep}worktrees${sep}`;
      const index = target.indexOf(marker);
      if (index >= 0) return target.slice(0, index);
    }
  } catch {}
  return physical;
}

// Preserve the producer's spelling as well as the header id. A later sweep can
// then recognize a hold even when it discovers the session by a physical path.
function rememberSessionAlias(root, harness, path, hash) {
  let descriptor;
  let lock;
  try {
    if (!path || !process.env.HOME || !["pi", "prime"].includes(harness)) return;
    const header = JSON.parse(boundedFirstLine(path));
    if (header?.type !== "session" || !Number.isInteger(header.version)
        || typeof header.id !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(header.id)
        || typeof header.cwd !== "string" || !isAbsolute(header.cwd)) return;
    const project = instanceRoot(root);
    const cwd = realpathSync(header.cwd);
    if (cwd !== project && !cwd.startsWith(project + sep)) return;
    const trails = join(process.env.HOME, ".egregore", "trails");
    mkdirSync(trails, { recursive: true, mode: 0o700 });
    const folder = join(trails, project.replace(/[/.]/g, "-") + `--${harness}`);
    try { mkdirSync(folder, { mode: 0o700 }); } catch (error) { if (error.code !== "EEXIST") throw error; }
    if (!lstatSync(folder).isDirectory() || dirname(realpathSync(folder)) !== realpathSync(trails)) return;
    const lockPath = join(folder, ".aliases.lock");
    try {
      mkdirSync(lockPath, { mode: 0o700 });
    } catch (error) {
      if (error.code !== "EEXIST") return;
      const info = lstatSync(lockPath);
      if (!info.isDirectory() || Date.now() - info.mtimeMs <= 60_000) return;
      // A crashed writer must not block future bindings. Remove only an empty
      // stale directory and retry acquisition once; a fresh owner wins.
      try {
        rmdirSync(lockPath);
        mkdirSync(lockPath, { mode: 0o700 });
      } catch { return; }
    }
    lock = lockPath;
    descriptor = openSync(join(folder, "aliases.jsonl"),
      constants.O_CREAT | constants.O_RDWR | constants.O_APPEND | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
    const info = fstatSync(descriptor);
    if (!info.isFile() || info.size > ALIAS_LIMIT) return;
    const content = Buffer.alloc(info.size);
    readSync(descriptor, content, 0, info.size, 0);
    if (content.toString("utf8").split("\n").some(line => {
      try { return JSON.parse(line).hash === hash; } catch { return false; }
    })) return;
    const entry = JSON.stringify({ hash, path: String(path), session: header.id }) + "\n";
    if (info.size + Buffer.byteLength(entry) > ALIAS_LIMIT) return;
    fchmodSync(descriptor, 0o600);
    writeSync(descriptor, entry);
  } catch {
    // Recording an identity alias must never interrupt the Observe boundary.
  } finally {
    if (descriptor !== undefined) try { closeSync(descriptor); } catch {}
    if (lock) try { rmdirSync(lock); } catch {}
  }
}

/** Put the session's own id in the environment of every command it runs. */
export function bindNativeSession(ctx, harness, root) {
  const session = sessionIdentity(ctx);
  if (session) {
    process.env.EGREGORE_NATIVE_SESSION_ID = session;
    process.env.EGREGORE_NATIVE_HARNESS = String(harness || "pi");
    rememberSessionAlias(root, String(harness || "pi"), ctx?.sessionManager?.getSessionFile?.(), session);
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
      const context = await compileObserveContext({ root, harness, prompt: "", sessionId: bindNativeSession(ctx, harness, root), signal: ctx?.signal });
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
      sessionId: bindNativeSession(ctx, harness, root),
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
