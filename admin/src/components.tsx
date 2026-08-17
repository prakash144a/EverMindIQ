/** Small shared pieces: formatting, stat tiles, tables, and async state. */

import type { ReactNode } from "react";
import { useEffect, useState } from "react";
import { ApiError } from "./api";

export function fmtDuration(seconds: number): string {
  if (!seconds) return "0s";
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.round(seconds % 60);
  if (m < 60) return s ? `${m}m ${s}s` : `${m}m`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

export function fmtDate(iso: string | null): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
  });
}

export function fmtWhen(iso: string | null): string {
  if (!iso) return "—";
  const then = new Date(iso).getTime();
  const mins = Math.round((Date.now() - then) / 60_000);
  if (mins < 1) return "just now";
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  if (days < 30) return `${days}d ago`;
  return fmtDate(iso);
}

/** Anonymous accounts are the majority before anyone verifies an email, so they
 * get a real label rather than an empty cell that reads as a broken row. */
export function displayName(user: { email: string; preferred_name: string }): ReactNode {
  if (user.preferred_name) return user.preferred_name;
  if (user.email) return user.email;
  return <span className="pill anon">Anonymous</span>;
}

export function Stat({
  label,
  value,
  hint,
}: {
  label: string;
  value: ReactNode;
  hint?: ReactNode;
}) {
  return (
    <div className="card stat">
      <div className="label">{label}</div>
      <div className="value">{value}</div>
      {hint ? <div className="hint">{hint}</div> : null}
    </div>
  );
}

export function ErrorBox({ error }: { error: unknown }) {
  const message =
    error instanceof ApiError && error.isForbidden
      ? "This account is not on the admin allowlist. Add its uid or verified email to VOICEIQ_ADMIN_UIDS / VOICEIQ_ADMIN_EMAILS and redeploy."
      : error instanceof Error
        ? error.message
        : String(error);
  return <div className="error">{message}</div>;
}

/** Minimal data-loading hook.
 *
 * A full query library would be more than this console needs — every page loads
 * once, and the operator can refresh. `deps` drives refetching on filter change.
 */
export function useAsync<T>(fn: () => Promise<T>, deps: unknown[]) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<unknown>(null);
  const [loading, setLoading] = useState(true);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fn()
      .then((value) => {
        if (!cancelled) {
          setData(value);
          setError(null);
        }
      })
      .catch((err) => {
        if (!cancelled) setError(err);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, nonce]);

  return { data, error, loading, reload: () => setNonce((n) => n + 1) };
}

export function Loading() {
  return <div className="empty">Loading…</div>;
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="empty">{children}</div>;
}

export function StatusPill({ status }: { status: string }) {
  const tone =
    status === "indexed" ? "ok" : status === "failed" ? "bad" : status === "new" ? "warn" : "";
  return <span className={`pill ${tone}`}>{status}</span>;
}
