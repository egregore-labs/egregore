/** Google Sheets operations via googleapis SDK. */

import { google } from "googleapis";
import type { CommandResult, SheetResult } from "./types.js";
import { getAuthClient } from "./auth.js";
import { cacheItem } from "./context.js";

export async function getSheet(
  spreadsheetId: string,
  range?: string,
): Promise<CommandResult<SheetResult>> {
  try {
    const sheets = google.sheets({ version: "v4", auth: await getAuthClient() });

    // Get spreadsheet metadata
    const metaResp = await sheets.spreadsheets.get({ spreadsheetId });
    const title = metaResp.data.properties?.title ?? "Untitled";
    const sheetMetas = metaResp.data.sheets ?? [];

    const resultSheets: SheetResult["sheets"] = [];

    for (const sheetMeta of sheetMetas) {
      const sheetTitle = sheetMeta.properties?.title ?? "Sheet1";
      const rowCount = sheetMeta.properties?.gridProperties?.rowCount ?? 0;

      const dataRange = range ?? sheetTitle;
      try {
        const valResp = await sheets.spreadsheets.values.get({
          spreadsheetId,
          range: dataRange,
        });

        const values = (valResp.data.values ?? []) as string[][];
        const headers = values.length > 0 ? values[0] : undefined;

        resultSheets.push({
          title: sheetTitle,
          headers,
          rowCount: values.length,
          data: values,
        });
      } catch {
        resultSheets.push({ title: sheetTitle, rowCount });
      }

      // Only fetch first sheet if no specific range
      if (!range) break;
    }

    const result: SheetResult = { id: spreadsheetId, title, sheets: resultSheets };
    cacheItem("sheets", spreadsheetId, { ...result, fetchedAt: new Date().toISOString() });
    return { ok: true, service: "sheets", command: "get", data: result };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return {
      ok: false,
      service: "sheets",
      command: "get",
      data: { id: spreadsheetId, title: "", sheets: [] },
      error: e.message,
    };
  }
}
