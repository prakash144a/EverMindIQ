/** Mirrors `backend/app/models/admin.py`.
 *
 * Note what is absent: there is no transcript, summary, title, tag, person, or
 * place anywhere in these types, because the API never sends them. That is a
 * deliberate boundary, not an oversight — see the module docstring on
 * `backend/app/api/routers/admin.py`. If you find yourself wanting to add one
 * here, the answer is on the server side and it is "no".
 */

export type Tier = "free" | "premium";

export interface UserRow {
  uid: string;
  email: string;
  email_verified: boolean;
  preferred_name: string;
  tier: Tier;
  install_id: string;
  platform: string;
  app_version: string;
  recordings_count: number;
  total_duration_sec: number;
  max_duration_sec: number;
  feedback_count: number;
  created_at: string;
  first_recorded_at: string | null;
  last_recording_at: string | null;
  last_active_at: string;
}

export interface RecordingRow {
  id: string;
  event_date: string;
  recorded_at: string;
  duration_sec: number;
  status: "uploaded" | "transcribing" | "indexed" | "failed";
  language: string;
  is_milestone: boolean;
}

export interface DeviceInfo {
  install_id: string;
  platform: string;
  app_version: string;
  first_seen_at: string;
  last_seen_at: string;
  account_count: number;
}

export interface DeviceAccount {
  uid: string;
  install_id: string;
  email: string;
  preferred_name: string;
  first_seen_at: string;
  last_seen_at: string;
}

export interface DeviceDetail {
  device: DeviceInfo;
  accounts: DeviceAccount[];
}

export interface UserDetail {
  user: UserRow;
  note: string;
  tier_updated_at: string | null;
  tier_updated_by: string;
  previous_uids: string[];
  devices: DeviceInfo[];
  recent_recordings: RecordingRow[];
}

export interface UserPage {
  items: UserRow[];
  next_cursor: string | null;
  sorted_by: string;
}

export interface DevicePage {
  items: DeviceInfo[];
  next_cursor: string | null;
}

export interface Overview {
  users_total: number;
  users_premium: number;
  users_with_email: number;
  users_anonymous: number;
  recordings_total: number;
  total_duration_sec: number;
  max_duration_sec: number;
  devices_total: number;
  multi_account_devices: number;
  active_1d: number;
  active_7d: number;
  active_30d: number;
  feedback_total: number;
  failed_recordings: number;
}

export interface FeedbackRow {
  id: string;
  uid: string;
  kind: string;
  message: string;
  diagnostics: string;
  app_version: string;
  platform: string;
  created_at: string;
  status: string;
  admin_note: string;
}

export interface FeedbackPage {
  items: FeedbackRow[];
  next_cursor: string | null;
}

export interface TimeSeriesPoint {
  day: string;
  value: number;
}

export interface TimeSeries {
  metric: string;
  points: TimeSeriesPoint[];
}

export interface Histogram {
  buckets: { label: string; count: number }[];
  total: number;
  p50_approx: number;
  p90_approx: number;
  max_duration_sec: number;
}

export interface AuditEntry {
  id: string;
  at: string;
  admin_uid: string;
  admin_email: string;
  action: string;
  target: string;
  detail: string;
}

export const SORTABLE = [
  "last_active_at",
  "created_at",
  "recordings_count",
  "total_duration_sec",
  "max_duration_sec",
  "email",
] as const;

export type SortField = (typeof SORTABLE)[number];
