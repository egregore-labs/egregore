/** Gmail operations via googleapis SDK. */

import { google } from "googleapis";
import { mkdirSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import type { gmail_v1 } from "googleapis";
import type {
  CommandResult,
  GmailAttachment,
  GmailAttachmentDownload,
  GmailListResult,
  GmailMessage,
} from "./types.js";
import { getAuthClient } from "./auth.js";
import { cacheItem, cacheList } from "./context.js";

async function getGmailClient() {
  return google.gmail({ version: "v1", auth: await getAuthClient() });
}

function decodeBase64Url(data: string): string {
  return Buffer.from(data.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf-8");
}

function walkParts(part: gmail_v1.Schema$MessagePart | undefined): gmail_v1.Schema$MessagePart[] {
  if (!part) return [];
  return [part, ...(part.parts ?? []).flatMap(walkParts)];
}

export function extractMessageContent(payload: gmail_v1.Schema$MessagePart | undefined): {
  body: string;
  attachments: GmailAttachment[];
} {
  const parts = walkParts(payload);
  const plain = parts.find((part) => part.mimeType === "text/plain" && part.body?.data);
  const html = parts.find((part) => part.mimeType === "text/html" && part.body?.data);
  const selectedBody = plain?.body?.data ?? html?.body?.data ?? payload?.body?.data ?? "";

  const attachments = parts
    .filter((part) => !!part.body?.attachmentId)
    .map((part) => ({
      id: part.body!.attachmentId!,
      filename: part.filename || "attachment",
      mimeType: part.mimeType || "application/octet-stream",
      size: part.body?.size ?? undefined,
    }));

  return {
    body: selectedBody ? decodeBase64Url(selectedBody) : "",
    attachments,
  };
}

function safeFilename(filename: string): string {
  const cleaned = filename.replace(/[\\/\0]/g, "_").replace(/^\.+/, "").trim();
  return cleaned || "attachment";
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

    const { body, attachments } = extractMessageContent(resp.data.payload ?? undefined);

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
      attachments,
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

export async function downloadAttachment(
  messageId: string,
  attachmentId: string,
  filename = "attachment",
  mimeType?: string,
): Promise<CommandResult<GmailAttachmentDownload>> {
  try {
    const gmail = await getGmailClient();
    const resp = await gmail.users.messages.attachments.get({
      userId: "me",
      messageId,
      id: attachmentId,
    });
    if (!resp.data.data) throw new Error("Attachment response contained no data");

    const data = Buffer.from(resp.data.data.replace(/-/g, "+").replace(/_/g, "/"), "base64");
    const targetDir = join(homedir(), ".egregore", "context", "google", "gmail", "attachments", messageId);
    mkdirSync(targetDir, { recursive: true, mode: 0o700 });
    const targetPath = join(targetDir, safeFilename(filename));
    writeFileSync(targetPath, data, { mode: 0o600 });

    return {
      ok: true,
      service: "gmail",
      command: "attachment",
      data: {
        messageId,
        attachmentId,
        filename: safeFilename(filename),
        mimeType,
        size: data.length,
        path: targetPath,
      },
    };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return {
      ok: false,
      service: "gmail",
      command: "attachment",
      data: { messageId, attachmentId, filename, mimeType, size: 0, path: "" },
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
