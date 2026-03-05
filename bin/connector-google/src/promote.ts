/** Prepare content for promotion from personal context to shared memory. */

import type { PromotionPayload, GoogleService, CachedItem } from "./types.js";
import { readState, getApiUrl, getApiKey } from "./config.js";
import { getCachedItem } from "./context.js";

/**
 * Build a promotion payload from a cached item.
 * Claude fills in summary, topics, mentions, quests during /ingest google.
 */
export function buildPromotionPayload(
  id: string,
  service: GoogleService,
  overrides: Partial<PromotionPayload> = {},
): PromotionPayload {
  const state = readState();
  const cached = getCachedItem(service, id) as Record<string, unknown> | null;

  const title = (cached?.title ?? cached?.name ?? cached?.subject ?? id) as string;
  const content = (cached?.content ?? cached?.body ?? JSON.stringify(cached, null, 2)) as string;

  const date = new Date().toISOString().slice(0, 10);
  const slug = title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 50);

  return {
    github_username: state.github_username ?? "",
    google_id: id,
    title,
    service,
    content,
    file_path: `knowledge/sources/google/${date}-${service}-${slug}.md`,
    summary: "",
    topics: [],
    mentioned_people: [],
    related_quests: [],
    ...overrides,
  };
}

/**
 * Send a promotion payload to the API for graph + memory processing.
 */
export async function promoteToShared(payload: PromotionPayload): Promise<{
  ok: boolean;
  error?: string;
  artifactId?: string;
}> {
  const apiUrl = getApiUrl();
  const apiKey = getApiKey();

  if (!apiUrl || !apiKey) {
    return { ok: false, error: "API URL or key not configured" };
  }

  try {
    const resp = await fetch(`${apiUrl}/api/connectors/google/promote`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });

    if (!resp.ok) {
      const detail = await resp.text();
      return { ok: false, error: `API error ${resp.status}: ${detail}` };
    }

    const data = (await resp.json()) as { status: string; artifact_id?: string };
    return { ok: true, artifactId: data.artifact_id };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return { ok: false, error: e.message };
  }
}

/**
 * Generate the markdown file content for shared memory.
 */
export function generateMarkdown(payload: PromotionPayload): string {
  const frontmatter = [
    "---",
    `title: "${payload.title.replace(/"/g, '\\"')}"`,
    `type: source`,
    `origin: google-${payload.service}`,
    `google_id: ${payload.google_id}`,
    `author: ${payload.github_username}`,
    `date: ${new Date().toISOString().slice(0, 10)}`,
    `summary: "${payload.summary.replace(/"/g, '\\"')}"`,
    `topics: [${payload.topics.join(", ")}]`,
    payload.mentioned_people.length
      ? `mentions: [${payload.mentioned_people.join(", ")}]`
      : null,
    payload.related_quests.length
      ? `quests: [${payload.related_quests.join(", ")}]`
      : null,
    "---",
  ]
    .filter(Boolean)
    .join("\n");

  return `${frontmatter}\n\n${payload.content}\n`;
}
