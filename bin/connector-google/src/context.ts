/** Personal context cache — ~/.egregore/context/google/ */

import { mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, existsSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import type { CachedItem, GoogleService } from "./types.js";

const CONTEXT_ROOT = join(homedir(), ".egregore", "context", "google");

const SERVICE_DIRS: GoogleService[] = ["drive", "gmail", "calendar", "docs", "sheets"];

export function ensureContextDirs(): void {
  for (const svc of SERVICE_DIRS) {
    mkdirSync(join(CONTEXT_ROOT, svc), { recursive: true });
  }
}

function servicePath(service: GoogleService, filename: string): string {
  return join(CONTEXT_ROOT, service, filename);
}

export function cacheItem(service: GoogleService, id: string, data: unknown): string {
  ensureContextDirs();
  const path = servicePath(service, `${id}.json`);
  writeFileSync(path, JSON.stringify(data, null, 2));
  return path;
}

export function getCachedItem(service: GoogleService, id: string): unknown | null {
  const path = servicePath(service, `${id}.json`);
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf-8"));
}

export function cacheList(service: GoogleService, data: unknown): string {
  ensureContextDirs();
  const path = servicePath(service, "latest-list.json");
  writeFileSync(path, JSON.stringify(data, null, 2));
  return path;
}

export function listCachedItems(service?: GoogleService): CachedItem[] {
  ensureContextDirs();
  const services = service ? [service] : SERVICE_DIRS;
  const items: CachedItem[] = [];

  for (const svc of services) {
    const dir = join(CONTEXT_ROOT, svc);
    if (!existsSync(dir)) continue;

    for (const file of readdirSync(dir)) {
      if (!file.endsWith(".json") || file === "latest-list.json" || file === "recent.json") continue;
      try {
        const data = JSON.parse(readFileSync(join(dir, file), "utf-8"));
        const id = file.replace(".json", "");
        items.push({
          id,
          service: svc,
          title: data.title || data.name || data.subject || id,
          fetchedAt: data.fetchedAt || "unknown",
          metadata: data.metadata || {},
          content: data.content ? `${String(data.content).slice(0, 200)}...` : undefined,
        });
      } catch {
        // Skip corrupt files
      }
    }
  }

  return items;
}

export function clearCache(service?: GoogleService): number {
  const services = service ? [service] : SERVICE_DIRS;
  let count = 0;

  for (const svc of services) {
    const dir = join(CONTEXT_ROOT, svc);
    if (!existsSync(dir)) continue;

    for (const file of readdirSync(dir)) {
      if (file.endsWith(".json")) {
        rmSync(join(dir, file));
        count++;
      }
    }
  }

  return count;
}

export function getContextRoot(): string {
  return CONTEXT_ROOT;
}
