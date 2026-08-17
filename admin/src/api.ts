/** Thin client for the backend's /admin API. */

import { idToken } from "./auth";
import type {
  AuditEntry,
  DeviceDetail,
  DevicePage,
  FeedbackPage,
  Histogram,
  Overview,
  RecordingRow,
  Tier,
  TimeSeries,
  UserDetail,
  UserPage,
} from "./types";

const BASE: string = import.meta.env.VITE_API_BASE_URL ?? "http://localhost:8000";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
  ) {
    super(message);
  }

  /** 403 means signed in but not on the allowlist — a different remedy from
   * 401, and worth telling the operator apart. */
  get isForbidden() {
    return this.status === 403;
  }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = await idToken();
  if (!token) throw new ApiError(401, "Not signed in");

  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      ...(init.headers ?? {}),
      Authorization: `Bearer ${token}`,
      ...(init.body ? { "Content-Type": "application/json" } : {}),
    },
  });

  if (res.status === 204) return undefined as T;
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const body = await res.json();
      detail = body.detail ?? detail;
    } catch {
      // A non-JSON error body (a proxy or gateway page) is not worth failing on.
    }
    throw new ApiError(res.status, detail);
  }
  return res.json() as Promise<T>;
}

function qs(params: Record<string, string | number | null | undefined>): string {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== null && value !== undefined && value !== "") search.set(key, String(value));
  }
  const s = search.toString();
  return s ? `?${s}` : "";
}

export const api = {
  me: () => request<{ uid: string; email: string; is_admin: boolean }>("/admin/me"),

  overview: () => request<Overview>("/admin/overview"),

  users: (params: {
    limit?: number;
    cursor?: string | null;
    sort?: string;
    order?: string;
    tier?: string | null;
    platform?: string | null;
    q?: string | null;
  }) => request<UserPage>(`/admin/users${qs(params)}`),

  userCount: () => request<{ value: number }>("/admin/users/count"),

  user: (uid: string) => request<UserDetail>(`/admin/users/${encodeURIComponent(uid)}`),

  setUser: (uid: string, body: { tier?: Tier; note?: string }) =>
    request<UserDetail["user"]>(`/admin/users/${encodeURIComponent(uid)}`, {
      method: "PATCH",
      body: JSON.stringify(body),
    }),

  recomputeStats: (uid: string) =>
    request<UserDetail["user"]>(`/admin/users/${encodeURIComponent(uid)}/recompute-stats`, {
      method: "POST",
    }),

  // The server also requires confirm_uid to equal uid. Sending it from one
  // place here keeps the console honest about how destructive this is.
  purgeUser: (uid: string) =>
    request<void>(
      `/admin/users/${encodeURIComponent(uid)}${qs({ confirm_uid: uid })}`,
      { method: "DELETE" },
    ),

  devices: (params: { limit?: number; cursor?: string | null }) =>
    request<DevicePage>(`/admin/devices${qs(params)}`),

  device: (installId: string) =>
    request<DeviceDetail>(`/admin/devices/${encodeURIComponent(installId)}`),

  feedback: (params: { limit?: number; cursor?: string | null; kind?: string | null }) =>
    request<FeedbackPage>(`/admin/feedback${qs(params)}`),

  triage: (id: string, body: { status?: string; admin_note?: string }) =>
    request<unknown>(`/admin/feedback/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: JSON.stringify(body),
    }),

  failedRecordings: () => request<RecordingRow[]>("/admin/recordings/failed"),

  timeseries: (metric: string, days = 30) => {
    const to = new Date();
    const from = new Date(to.getTime() - days * 86_400_000);
    return request<TimeSeries>(
      `/admin/metrics/timeseries${qs({
        metric,
        date_from: from.toISOString().slice(0, 10),
        date_to: to.toISOString().slice(0, 10),
      })}`,
    );
  },

  histogram: () => request<Histogram>("/admin/metrics/duration-histogram"),

  audit: () => request<{ items: AuditEntry[] }>("/admin/audit"),
};
