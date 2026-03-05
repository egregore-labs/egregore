/** Gmail operations via googleapis SDK. */

import { google } from "googleapis";
import type { CommandResult, GmailListResult, GmailMessage } from "./types.js";
import { getAuthClient } from "./auth.js";
import { cacheItem, cacheList } from "./context.js";

async function getGmailClient() {
  return google.gmail({ version: "v1", auth: await getAuthClient() });
}

export async function listMessages(opts: {
  label?: string;
  since?: string;
  max?: number;
}): Promise<CommandResult<GmailListResult>> {
  const maxResults = opts.max ?? 10;
  let q = "";
  if (opts.label) q += `label:${opts.label} `;
  if (opts.since) q += `after:${opts.since} `;
  q = q.trim();

  try {
    const gmail = await getGmailClient();
    const listResp = await gmail.users.messages.list({
      userId: "me",
      maxResults,
      ...(q ? { q } : {}),
    });

    const rawMessages = listResp.data.messages ?? [];
    const messages: GmailMessage[] = [];

    for (const msg of rawMessages.slice(0, maxResults)) {
      if (!msg.id) continue;
      try {
        const detail = await gmail.users.messages.get({
          userId: "me",
          id: msg.id,
          format: "metadata",
          metadataHeaders: ["Subject", "From", "To", "Date"],
        });

        const headers = detail.data.payload?.headers ?? [];
        const getHeader = (name: string) => headers.find((h) => h.name === name)?.value;

        messages.push({
          id: detail.data.id ?? msg.id,
          threadId: detail.data.threadId ?? msg.threadId ?? "",
          snippet: detail.data.snippet ?? "",
          subject: getHeader("Subject"),
          from: getHeader("From"),
          to: getHeader("To"),
          date: getHeader("Date"),
          labelIds: detail.data.labelIds ?? undefined,
        });
      } catch {
        messages.push({ id: msg.id, threadId: msg.threadId ?? "", snippet: "" });
      }
    }

    const result: GmailListResult = {
      messages,
      nextPageToken: listResp.data.nextPageToken ?? undefined,
    };
    cacheList("gmail", { ...result, fetchedAt: new Date().toISOString() });
    return { ok: true, service: "gmail", command: "list", data: result };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return { ok: false, service: "gmail", command: "list", data: { messages: [] }, error: e.message };
  }
}

export async function getMessage(messageId: string): Promise<CommandResult<GmailMessage>> {
  try {
    const gmail = await getGmailClient();
    const resp = await gmail.users.messages.get({
      userId: "me",
      id: messageId,
      format: "full",
    });

    const headers = resp.data.payload?.headers ?? [];
    const getHeader = (name: string) => headers.find((h) => h.name === name)?.value;

    // Extract body — try plain text part first
    let body = "";
    const parts = resp.data.payload?.parts;
    if (parts) {
      const textPart = parts.find((p) => p.mimeType === "text/plain");
      if (textPart?.body?.data) {
        body = Buffer.from(textPart.body.data, "base64").toString("utf-8");
      }
    } else if (resp.data.payload?.body?.data) {
      body = Buffer.from(resp.data.payload.body.data, "base64").toString("utf-8");
    }

    const message: GmailMessage = {
      id: resp.data.id ?? messageId,
      threadId: resp.data.threadId ?? "",
      snippet: resp.data.snippet ?? "",
      subject: getHeader("Subject"),
      from: getHeader("From"),
      to: getHeader("To"),
      date: getHeader("Date"),
      labelIds: resp.data.labelIds ?? undefined,
      body,
    };

    cacheItem("gmail", messageId, { ...message, fetchedAt: new Date().toISOString() });
    return { ok: true, service: "gmail", command: "get", data: message };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return {
      ok: false,
      service: "gmail",
      command: "get",
      data: { id: messageId, threadId: "", snippet: "" },
      error: e.message,
    };
  }
}

export async function searchMessages(query: string): Promise<CommandResult<GmailListResult>> {
  try {
    const gmail = await getGmailClient();
    const listResp = await gmail.users.messages.list({
      userId: "me",
      maxResults: 10,
      q: query,
    });

    const rawMessages = listResp.data.messages ?? [];
    const messages: GmailMessage[] = [];

    for (const msg of rawMessages.slice(0, 10)) {
      if (!msg.id) continue;
      try {
        const detail = await gmail.users.messages.get({
          userId: "me",
          id: msg.id,
          format: "metadata",
          metadataHeaders: ["Subject", "From", "To", "Date"],
        });

        const headers = detail.data.payload?.headers ?? [];
        const getHeader = (name: string) => headers.find((h) => h.name === name)?.value;

        messages.push({
          id: detail.data.id ?? msg.id,
          threadId: detail.data.threadId ?? msg.threadId ?? "",
          snippet: detail.data.snippet ?? "",
          subject: getHeader("Subject"),
          from: getHeader("From"),
          to: getHeader("To"),
          date: getHeader("Date"),
          labelIds: detail.data.labelIds ?? undefined,
        });
      } catch {
        messages.push({ id: msg.id, threadId: msg.threadId ?? "", snippet: "" });
      }
    }

    const result: GmailListResult = {
      messages,
      nextPageToken: listResp.data.nextPageToken ?? undefined,
    };
    cacheList("gmail", { ...result, fetchedAt: new Date().toISOString(), searchQuery: query });
    return { ok: true, service: "gmail", command: "search", data: result };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return { ok: false, service: "gmail", command: "search", data: { messages: [] }, error: e.message };
  }
}
