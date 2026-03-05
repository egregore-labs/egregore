/** Google Workspace connector shared types. */

export type GoogleService = "drive" | "gmail" | "calendar" | "docs" | "sheets";

export interface ConnectorConfig {
  enabled: boolean;
  services: GoogleService[];
  scopes?: {
    drive?: { folders?: string[] };
    gmail?: { labels?: string[] };
    calendar?: { calendars?: string[] };
  };
}

export interface EgregoreConfig {
  org_name: string;
  github_org: string;
  memory_repo: string;
  api_url: string;
  repo_name: string;
  slug: string;
  repos: string[];
  connectors?: {
    google?: ConnectorConfig;
  };
}

export interface UserState {
  github_username?: string;
  name?: string;
  onboarding_complete?: boolean;
  google_connector?: boolean;
  google_auth_complete?: boolean;
  google_account?: string;
  google_services?: GoogleService[];
  google_last_sync?: string;
  [key: string]: unknown;
}

export interface AuthStatus {
  connected: boolean;
  account?: string;
  error?: string;
}

export interface CommandResult<T = unknown> {
  ok: boolean;
  service: string;
  command: string;
  data: T;
  error?: string;
}

export interface DriveFile {
  id: string;
  name: string;
  mimeType: string;
  modifiedTime?: string;
  owners?: Array<{ displayName: string; emailAddress: string }>;
  webViewLink?: string;
  parents?: string[];
}

export interface DriveListResult {
  files: DriveFile[];
  nextPageToken?: string;
}

export interface DriveFileResult {
  metadata: DriveFile;
  content?: string;
}

export interface GmailMessage {
  id: string;
  threadId: string;
  snippet: string;
  subject?: string;
  from?: string;
  to?: string;
  date?: string;
  labelIds?: string[];
  body?: string;
}

export interface GmailListResult {
  messages: GmailMessage[];
  nextPageToken?: string;
}

export interface CalendarEvent {
  id: string;
  summary: string;
  description?: string;
  start: string;
  end: string;
  attendees?: Array<{ email: string; displayName?: string; responseStatus?: string }>;
  location?: string;
  htmlLink?: string;
}

export interface CalendarListResult {
  events: CalendarEvent[];
}

export interface DocResult {
  id: string;
  title: string;
  content: string;
  revisionId?: string;
}

export interface SheetResult {
  id: string;
  title: string;
  sheets: Array<{
    title: string;
    headers?: string[];
    rowCount: number;
    data?: string[][];
  }>;
}

export interface PromotionPayload {
  github_username: string;
  google_id: string;
  title: string;
  service: GoogleService;
  content: string;
  file_path: string;
  summary: string;
  topics: string[];
  mentioned_people: string[];
  related_quests: string[];
}

export interface CachedItem {
  id: string;
  service: GoogleService;
  title: string;
  fetchedAt: string;
  metadata: Record<string, unknown>;
  content?: string;
}
