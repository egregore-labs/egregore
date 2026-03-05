/** Google Docs operations via googleapis SDK — exports as plain text. */

import { google } from "googleapis";
import type { CommandResult, DocResult } from "./types.js";
import { getAuthClient } from "./auth.js";
import { cacheItem } from "./context.js";

export async function getDoc(docId: string): Promise<CommandResult<DocResult>> {
  try {
    const auth = await getAuthClient();
    const docs = google.docs({ version: "v1", auth });

    // Get document metadata + body
    const resp = await docs.documents.get({ documentId: docId });
    const title = resp.data.title ?? "Untitled";

    // Export as plain text via Drive (more reliable for clean text)
    let content = "";
    try {
      const drive = google.drive({ version: "v3", auth });
      const exportResp = await drive.files.export({
        fileId: docId,
        mimeType: "text/plain",
      });
      content = String(exportResp.data);
    } catch {
      // Fallback: extract text from document body
      content = extractTextFromDoc(resp.data);
    }

    const result: DocResult = {
      id: docId,
      title,
      content,
      revisionId: resp.data.revisionId ?? undefined,
    };

    cacheItem("docs", docId, { ...result, fetchedAt: new Date().toISOString() });
    return { ok: true, service: "docs", command: "get", data: result };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return {
      ok: false,
      service: "docs",
      command: "get",
      data: { id: docId, title: "", content: "" },
      error: e.message,
    };
  }
}

function extractTextFromDoc(doc: Record<string, unknown>): string {
  const body = doc.body as { content?: Array<Record<string, unknown>> } | undefined;
  if (!body?.content) return "";

  const lines: string[] = [];
  for (const element of body.content) {
    const paragraph = element.paragraph as {
      elements?: Array<{ textRun?: { content?: string } }>;
    } | undefined;
    if (paragraph?.elements) {
      const text = paragraph.elements
        .map((e) => e.textRun?.content ?? "")
        .join("");
      lines.push(text);
    }
  }
  return lines.join("");
}
