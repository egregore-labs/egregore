#!/usr/bin/env node
/** Google Workspace connector CLI entry point. */

import { authSetup, authRevoke, listConnectedAccounts, printAuthStatus } from "./auth.js";
import { listFiles, getFile, searchFiles } from "./drive.js";
import { downloadAttachment, listMessages, getMessage, searchMessages } from "./gmail.js";
import { listEvents, getEvent } from "./calendar.js";
import { getDoc } from "./docs.js";
import { getSheet } from "./sheets.js";
import { listCachedItems, clearCache, getCachedItem, ensureContextDirs } from "./context.js";
import { buildPromotionPayload } from "./promote.js";
import { readState, getConnectorConfig, getLocalEnvValue, writeState } from "./config.js";
import { authStatus } from "./auth.js";
import type { GoogleService } from "./types.js";

const args = process.argv.slice(2);
const command = args[0];
const subcommand = args[1];

function printJson(data: unknown): void {
  console.log(JSON.stringify(data, null, 2));
}

function usage(): void {
  console.log(`connector-google <command>

Setup:
  check              Verify OAuth credentials + auth status
  auth               Run Google OAuth setup (opens browser)
  auth status        Check auth state
  auth revoke        Revoke Google access
  auth accounts      List connected Google accounts
  enable [services]  Enable services for current user
  status             Show full connector status

Data:
  drive list [--folder NAME] [--max N]
  drive get <file-id>
  drive search <query>
  drive search-all <query>
  gmail list [--label X] [--since DATE] [--max N]
  gmail get <message-id>
  gmail search <query>
  gmail search-all <query>
  gmail attachment <message-id> <attachment-id> [--filename NAME] [--mime-type TYPE]
  calendar list [--since DATE] [--until DATE]
  calendar list-all [--since DATE] [--until DATE]
  calendar get <event-id>
  docs get <doc-id>
  sheets get <sheet-id> [range]

Context:
  context list               List cached items
  context show <id>          Show a cached item
  context clear [service]    Clear cache
  promote <service> <id>     Prepare item for promotion (outputs JSON)

Account selection:
  --account EMAIL            Run a command as one connected account
  search-all / list-all      Query every connected account`);
}

function parseFlag(flag: string): string | undefined {
  const idx = args.indexOf(flag);
  if (idx === -1 || idx + 1 >= args.length) return undefined;
  return args[idx + 1];
}

const requestedAccount = parseFlag("--account");
if (requestedAccount) process.env.EGREGORE_GOOGLE_ACCOUNT = requestedAccount;

function queryFrom(start: number): string {
  const values = args.slice(start);
  const accountFlag = values.indexOf("--account");
  if (accountFlag !== -1) values.splice(accountFlag, 2);
  return values.join(" ");
}

async function runAcrossAccounts<T>(operation: () => Promise<T>): Promise<Array<{ account: string; result: T | { error: string } }>> {
  const previous = process.env.EGREGORE_GOOGLE_ACCOUNT;
  const results: Array<{ account: string; result: T | { error: string } }> = [];
  for (const account of listConnectedAccounts()) {
    process.env.EGREGORE_GOOGLE_ACCOUNT = account;
    try {
      results.push({ account, result: await operation() });
    } catch (err: unknown) {
      results.push({ account, result: { error: (err as { message?: string }).message ?? "Unknown error" } });
    }
  }
  if (previous) process.env.EGREGORE_GOOGLE_ACCOUNT = previous;
  else delete process.env.EGREGORE_GOOGLE_ACCOUNT;
  return results;
}

async function main(): Promise<void> {
  if (!command || command === "help" || command === "--help") {
    usage();
    return;
  }

  // --- Setup commands ---

  if (command === "check") {
    // Check if Google OAuth credentials are configured
    const hasCredentials = !!(
      (process.env.GOOGLE_CLIENT_ID || getLocalEnvValue("GOOGLE_CLIENT_ID")) &&
      (process.env.GOOGLE_CLIENT_SECRET || getLocalEnvValue("GOOGLE_CLIENT_SECRET"))
    );
    const status = await authStatus();
    console.log(`OAuth credentials: ${hasCredentials ? "configured" : "not set (need GOOGLE_CLIENT_ID + GOOGLE_CLIENT_SECRET in .env)"}`);
    console.log(`Auth status: ${status.connected ? `connected (${status.account})` : "not connected"}`);
    process.exit(hasCredentials ? 0 : 1);
  }

  if (command === "auth") {
    if (subcommand === "status") {
      await printAuthStatus(requestedAccount);
    } else if (subcommand === "revoke") {
      await authRevoke(requestedAccount);
    } else if (subcommand === "accounts") {
      printJson({ accounts: listConnectedAccounts(), active: requestedAccount ?? readState().google_account });
    } else {
      await authSetup();
    }
    return;
  }

  if (command === "enable") {
    const services = args.slice(1) as GoogleService[];
    if (services.length === 0) {
      const config = getConnectorConfig();
      const available = config?.services ?? ["drive", "gmail", "calendar", "docs", "sheets"];
      console.log(`Available services: ${available.join(", ")}`);
      console.log("Usage: enable drive gmail calendar");
      return;
    }
    writeState({ google_services: services });
    console.log(`Enabled services: ${services.join(", ")}`);
    return;
  }

  if (command === "status") {
    const state = readState();
    const config = getConnectorConfig();
    console.log("Google Workspace Connector Status");
    console.log("─".repeat(40));
    console.log(`Org enabled:    ${config?.enabled ?? false}`);
    console.log(`User connected: ${state.google_auth_complete ?? false}`);
    console.log(`Account:        ${state.google_account ?? "none"}`);
    console.log(`Services:       ${(state.google_services ?? config?.services ?? []).join(", ") || "none"}`);
    console.log(`Last sync:      ${state.google_last_sync ?? "never"}`);
    return;
  }

  // --- Data commands ---

  if (command === "drive") {
    if (subcommand === "list") {
      const result = await listFiles({
        folder: parseFlag("--folder"),
        max: parseFlag("--max") ? parseInt(parseFlag("--max")!) : undefined,
      });
      printJson(result);
    } else if (subcommand === "get" && args[2]) {
      const result = await getFile(args[2]);
      printJson(result);
    } else if (subcommand === "search" && args[2]) {
      const result = await searchFiles(queryFrom(2));
      printJson(result);
    } else if (subcommand === "search-all" && args[2]) {
      printJson({ ok: true, service: "drive", command: "search-all", data: await runAcrossAccounts(() => searchFiles(queryFrom(2))) });
    } else {
      console.error("Usage: drive list|get|search|search-all");
      process.exit(1);
    }
    return;
  }

  if (command === "gmail") {
    if (subcommand === "list") {
      const result = await listMessages({
        label: parseFlag("--label"),
        since: parseFlag("--since"),
        max: parseFlag("--max") ? parseInt(parseFlag("--max")!) : undefined,
      });
      printJson(result);
    } else if (subcommand === "get" && args[2]) {
      const result = await getMessage(args[2]);
      printJson(result);
    } else if (subcommand === "search" && args[2]) {
      const result = await searchMessages(queryFrom(2));
      printJson(result);
    } else if (subcommand === "search-all" && args[2]) {
      printJson({ ok: true, service: "gmail", command: "search-all", data: await runAcrossAccounts(() => searchMessages(queryFrom(2))) });
    } else if (subcommand === "attachment" && args[2] && args[3]) {
      const result = await downloadAttachment(
        args[2],
        args[3],
        parseFlag("--filename") ?? "attachment",
        parseFlag("--mime-type"),
      );
      printJson(result);
    } else {
      console.error("Usage: gmail list|get|search|search-all|attachment");
      process.exit(1);
    }
    return;
  }

  if (command === "calendar") {
    if (subcommand === "list") {
      const result = await listEvents({
        since: parseFlag("--since"),
        until: parseFlag("--until"),
      });
      printJson(result);
    } else if (subcommand === "list-all") {
      printJson({
        ok: true,
        service: "calendar",
        command: "list-all",
        data: await runAcrossAccounts(() => listEvents({ since: parseFlag("--since"), until: parseFlag("--until") })),
      });
    } else if (subcommand === "get" && args[2]) {
      const result = await getEvent(args[2]);
      printJson(result);
    } else {
      console.error("Usage: calendar list|list-all|get");
      process.exit(1);
    }
    return;
  }

  if (command === "docs") {
    if (subcommand === "get" && args[2]) {
      const result = await getDoc(args[2]);
      printJson(result);
    } else {
      console.error("Usage: docs get <doc-id>");
      process.exit(1);
    }
    return;
  }

  if (command === "sheets") {
    if (subcommand === "get" && args[2]) {
      const result = await getSheet(args[2], args[3]);
      printJson(result);
    } else {
      console.error("Usage: sheets get <sheet-id> [range]");
      process.exit(1);
    }
    return;
  }

  // --- Context commands ---

  if (command === "context") {
    if (subcommand === "list") {
      const service = args[2] as GoogleService | undefined;
      const items = listCachedItems(service);
      if (items.length === 0) {
        console.log("No cached items.");
      } else {
        printJson(items);
      }
    } else if (subcommand === "show" && args[2]) {
      // Try each service
      for (const svc of ["drive", "gmail", "calendar", "docs", "sheets"] as GoogleService[]) {
        const item = getCachedItem(svc, args[2]);
        if (item) {
          printJson(item);
          return;
        }
      }
      console.error(`Item ${args[2]} not found in cache.`);
      process.exit(1);
    } else if (subcommand === "clear") {
      const service = args[2] as GoogleService | undefined;
      const count = clearCache(service);
      console.log(`Cleared ${count} cached items.`);
    } else {
      console.error("Usage: context list|show|clear");
      process.exit(1);
    }
    return;
  }

  // --- Promotion ---

  if (command === "promote") {
    const service = args[1] as GoogleService;
    const id = args[2];
    if (!service || !id) {
      console.error("Usage: promote <service> <id>");
      process.exit(1);
    }
    const payload = buildPromotionPayload(id, service);
    printJson(payload);
    return;
  }

  // --- Sync ---

  if (command === "sync") {
    ensureContextDirs();
    const services = (args[1] ? [args[1]] : ["drive", "gmail", "calendar"]) as GoogleService[];
    console.log(`Syncing: ${services.join(", ")}...`);

    for (const svc of services) {
      try {
        if (svc === "drive") await listFiles({ max: 25 });
        if (svc === "gmail") await listMessages({ max: 10 });
        if (svc === "calendar") await listEvents({});
        console.log(`  ${svc}: synced`);
      } catch (err: unknown) {
        const e = err as { message?: string };
        console.error(`  ${svc}: failed — ${e.message}`);
      }
    }

    writeState({ google_last_sync: new Date().toISOString() });
    console.log("Sync complete.");
    return;
  }

  console.error(`Unknown command: ${command}`);
  usage();
  process.exit(1);
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
