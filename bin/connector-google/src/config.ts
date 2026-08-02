/** Read egregore.json and .egregore-state.json. */

import { readFileSync, writeFileSync, existsSync } from "fs";
import { resolve, dirname } from "path";
import { fileURLToPath } from "url";
import type { EgregoreConfig, UserState, ConnectorConfig, GoogleService } from "./types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
export const PROJECT_ROOT = resolve(__dirname, "../../..");

const EGREGORE_JSON = resolve(PROJECT_ROOT, "egregore.json");
const STATE_JSON = resolve(PROJECT_ROOT, ".egregore-state.json");

export function readConfig(): EgregoreConfig {
  if (!existsSync(EGREGORE_JSON)) {
    throw new Error("egregore.json not found. Run onboarding first.");
  }
  return JSON.parse(readFileSync(EGREGORE_JSON, "utf-8"));
}

export function readState(): UserState {
  if (!existsSync(STATE_JSON)) {
    return {};
  }
  return JSON.parse(readFileSync(STATE_JSON, "utf-8"));
}

export function writeState(updates: Partial<UserState>): void {
  const current = readState();
  const merged = { ...current, ...updates };
  writeFileSync(STATE_JSON, JSON.stringify(merged, null, 2) + "\n");
}

export function getConnectorConfig(): ConnectorConfig | null {
  const config = readConfig();
  return config.connectors?.google ?? null;
}

export function getApiUrl(): string {
  return readConfig().api_url;
}

export function getApiKey(): string {
  const envPath = resolve(PROJECT_ROOT, ".env");
  if (!existsSync(envPath)) return "";
  const content = readFileSync(envPath, "utf-8");
  const match = content.match(/^EGREGORE_API_KEY=(.+)$/m);
  return match ? match[1].trim() : "";
}

export function getLocalEnvValue(key: string): string {
  const envPath = resolve(PROJECT_ROOT, ".env");
  if (!existsSync(envPath)) return "";
  const content = readFileSync(envPath, "utf-8");
  const match = content.match(new RegExp(`^${key}=(.+)$`, "m"));
  return match ? match[1].trim() : "";
}

export function isHosted(): boolean {
  return !!process.env.CODER || !!process.env.CODER_WORKSPACE_NAME;
}

export function getEnabledServices(): GoogleService[] {
  const state = readState();
  if (state.google_services?.length) return state.google_services;
  const config = getConnectorConfig();
  return config?.services ?? ["drive", "gmail", "calendar", "docs", "sheets"];
}
