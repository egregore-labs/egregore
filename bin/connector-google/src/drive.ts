/** Google Drive operations via googleapis SDK. */

import { google } from "googleapis";
import type { CommandResult, DriveListResult, DriveFileResult, DriveFile } from "./types.js";
import { getAuthClient } from "./auth.js";
import { cacheItem, cacheList } from "./context.js";

async function getDriveClient() {
  return google.drive({ version: "v3", auth: await getAuthClient() });
}

export async function listFiles(opts: {
  folder?: string;
  max?: number;
}): Promise<CommandResult<DriveListResult>> {
  const pageSize = opts.max ?? 25;
  let q = "trashed = false";
  if (opts.folder) {
    q += ` and '${opts.folder}' in parents`;
  }

  try {
    const drive = await getDriveClient();
    const resp = await drive.files.list({
      pageSize,
      q,
      fields: "files(id,name,mimeType,modifiedTime,owners,webViewLink,parents),nextPageToken",
      orderBy: "modifiedTime desc",
    });

    const files = (resp.data.files ?? []).map(normalizeDriveFile);
    const result: DriveListResult = { files, nextPageToken: resp.data.nextPageToken ?? undefined };
    cacheList("drive", { ...result, fetchedAt: new Date().toISOString() });
    return { ok: true, service: "drive", command: "list", data: result };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return { ok: false, service: "drive", command: "list", data: { files: [] }, error: e.message };
  }
}

export async function getFile(fileId: string): Promise<CommandResult<DriveFileResult>> {
  try {
    const drive = await getDriveClient();

    const metaResp = await drive.files.get({
      fileId,
      fields: "id,name,mimeType,modifiedTime,owners,webViewLink,parents",
    });
    const metadata = normalizeDriveFile(metaResp.data);

    let content: string | undefined;

    // For Google Docs, export as plain text
    if (metadata.mimeType === "application/vnd.google-apps.document") {
      try {
        const exportResp = await drive.files.export({ fileId, mimeType: "text/plain" });
        content = String(exportResp.data);
      } catch { /* fall through */ }
    }

    // For Google Sheets, export as CSV
    if (metadata.mimeType === "application/vnd.google-apps.spreadsheet") {
      try {
        const exportResp = await drive.files.export({ fileId, mimeType: "text/csv" });
        content = String(exportResp.data);
      } catch { /* fall through */ }
    }

    // For Google Slides, export as plain text
    if (metadata.mimeType === "application/vnd.google-apps.presentation") {
      try {
        const exportResp = await drive.files.export({ fileId, mimeType: "text/plain" });
        content = String(exportResp.data);
      } catch { /* fall through */ }
    }

    const result: DriveFileResult = { metadata, content };
    cacheItem("drive", fileId, { ...result, fetchedAt: new Date().toISOString() });
    return { ok: true, service: "drive", command: "get", data: result };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return {
      ok: false,
      service: "drive",
      command: "get",
      data: { metadata: { id: fileId, name: "", mimeType: "" } },
      error: e.message,
    };
  }
}

export async function searchFiles(query: string): Promise<CommandResult<DriveListResult>> {
  try {
    const drive = await getDriveClient();
    const resp = await drive.files.list({
      pageSize: 25,
      q: `fullText contains '${query.replace(/'/g, "\\'")}' and trashed = false`,
      fields: "files(id,name,mimeType,modifiedTime,owners,webViewLink,parents),nextPageToken",
      orderBy: "modifiedTime desc",
    });

    const files = (resp.data.files ?? []).map(normalizeDriveFile);
    const result: DriveListResult = { files, nextPageToken: resp.data.nextPageToken ?? undefined };
    cacheList("drive", { ...result, fetchedAt: new Date().toISOString(), searchQuery: query });
    return { ok: true, service: "drive", command: "search", data: result };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return { ok: false, service: "drive", command: "search", data: { files: [] }, error: e.message };
  }
}

function normalizeDriveFile(f: Record<string, unknown>): DriveFile {
  return {
    id: (f.id as string) ?? "",
    name: (f.name as string) ?? "",
    mimeType: (f.mimeType as string) ?? "",
    modifiedTime: f.modifiedTime as string | undefined,
    owners: f.owners as DriveFile["owners"],
    webViewLink: f.webViewLink as string | undefined,
    parents: f.parents as string[] | undefined,
  };
}
