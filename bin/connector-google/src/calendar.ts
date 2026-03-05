/** Google Calendar operations via googleapis SDK. */

import { google } from "googleapis";
import type { CommandResult, CalendarListResult, CalendarEvent } from "./types.js";
import { getAuthClient } from "./auth.js";
import { cacheItem, cacheList } from "./context.js";

async function getCalendarClient() {
  return google.calendar({ version: "v3", auth: await getAuthClient() });
}

export async function listEvents(opts: {
  since?: string;
  until?: string;
  calendarId?: string;
}): Promise<CommandResult<CalendarListResult>> {
  const calendarId = opts.calendarId ?? "primary";
  const timeMin = opts.since ?? new Date().toISOString();
  const timeMax = opts.until ?? new Date(Date.now() + 14 * 24 * 60 * 60 * 1000).toISOString();

  try {
    const calendar = await getCalendarClient();
    const resp = await calendar.events.list({
      calendarId,
      timeMin,
      timeMax,
      maxResults: 50,
      singleEvents: true,
      orderBy: "startTime",
    });

    const events: CalendarEvent[] = (resp.data.items ?? []).map(normalizeEvent);
    const result: CalendarListResult = { events };
    cacheList("calendar", { ...result, fetchedAt: new Date().toISOString() });
    return { ok: true, service: "calendar", command: "list", data: result };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return { ok: false, service: "calendar", command: "list", data: { events: [] }, error: e.message };
  }
}

export async function getEvent(
  eventId: string,
  calendarId?: string,
): Promise<CommandResult<CalendarEvent>> {
  const cal = calendarId ?? "primary";

  try {
    const calendar = await getCalendarClient();
    const resp = await calendar.events.get({ calendarId: cal, eventId });
    const event = normalizeEvent(resp.data);

    cacheItem("calendar", eventId, { ...event, fetchedAt: new Date().toISOString() });
    return { ok: true, service: "calendar", command: "get", data: event };
  } catch (err: unknown) {
    const e = err as { message?: string };
    return {
      ok: false,
      service: "calendar",
      command: "get",
      data: { id: eventId, summary: "", start: "", end: "" },
      error: e.message,
    };
  }
}

function normalizeEvent(item: Record<string, unknown>): CalendarEvent {
  const start = item.start as Record<string, string> | undefined;
  const end = item.end as Record<string, string> | undefined;

  return {
    id: (item.id as string) ?? "",
    summary: (item.summary as string) ?? "(no title)",
    description: item.description as string | undefined,
    start: start?.dateTime ?? start?.date ?? "",
    end: end?.dateTime ?? end?.date ?? "",
    attendees: item.attendees as CalendarEvent["attendees"],
    location: item.location as string | undefined,
    htmlLink: item.htmlLink as string | undefined,
  };
}
