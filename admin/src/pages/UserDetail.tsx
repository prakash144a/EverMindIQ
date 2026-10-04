import { useState } from "react";
import { api } from "../api";
import {
  Empty,
  ErrorBox,
  Loading,
  Stat,
  StatusPill,
  displayName,
  fmtDate,
  fmtDuration,
  fmtWhen,
  useAsync,
} from "../components";
import { navigate } from "../router";

export function UserDetail({ uid }: { uid: string }) {
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);
  const detail = useAsync(() => api.user(uid), [uid]);

  if (detail.error) return <ErrorBox error={detail.error} />;
  if (detail.loading || !detail.data) return <Loading />;

  const { user, note } = detail.data;
  // Defaulted rather than trusted: this page once went blank because it read a
  // list the API had stopped sending. A missing list is an empty one.
  const devices = detail.data.devices ?? [];
  const recent_recordings = detail.data.recent_recordings ?? [];
  const isPro = user.tier === "premium";

  async function run(action: () => Promise<unknown>) {
    setBusy(true);
    setActionError(null);
    try {
      await action();
      detail.reload();
    } catch (e) {
      // Said on the page: a button that does nothing when it fails looks the
      // same as one that worked.
      setActionError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function setPlan(pro: boolean) {
    const who = user.email || user.uid;
    const ok = window.confirm(
      pro
        ? `Upgrade ${who} to the Pro plan?\n\nThe higher limits apply from their next request. Nothing is charged — this is a manual grant.`
        : `Move ${who} back to the Free plan?\n\nNothing they have recorded is removed, but the free limits apply from their next request.`,
    );
    if (!ok) return;
    await run(() => api.setUser(uid, { tier: pro ? "premium" : "free" }));
  }

  async function purge() {
    const confirmed = window.prompt(
      `This permanently deletes this account and every recording, transcript and audio file in it. It cannot be undone.\n\nType the uid to confirm:`,
    );
    if (confirmed !== uid) return;
    await run(async () => {
      await api.purgeUser(uid);
      navigate("/users");
    });
  }

  return (
    <>
      <p className="small">
        <a onClick={() => navigate("/users")}>← People</a>
      </p>
      <h1>
        {displayName(user)}{" "}
        <span className={`pill ${isPro ? "premium" : ""}`}>{isPro ? "Pro" : "Free"}</span>
      </h1>
      <p className="muted mono small">{user.uid}</p>

      <div className="grid">
        <Stat label="Recordings" value={user.recordings_count} />
        <Stat
          label="Longest"
          value={fmtDuration(user.max_duration_sec)}
          hint="longest ever; not lowered by deletes"
        />
        <Stat label="Total captured" value={fmtDuration(user.total_duration_sec)} />
        <Stat label="Last active" value={fmtWhen(user.last_active_at)} />
      </div>

      <div className="card section">
        <h2>Account</h2>
        <table>
          <tbody>
            <Row label="Email">
              {user.email ? (
                <>
                  {user.email}{" "}
                  {user.email_verified ? (
                    <span className="pill ok">verified</span>
                  ) : (
                    <span className="pill warn">unverified</span>
                  )}
                </>
              ) : (
                <span className="muted">none — anonymous account</span>
              )}
            </Row>
            <Row label="Name">{user.preferred_name || <span className="muted">—</span>}</Row>
            <Row label="Joined">{fmtDate(user.created_at)}</Row>
            <Row label="First recording">{fmtWhen(user.first_recorded_at)}</Row>
            <Row label="Latest recording">{fmtWhen(user.last_recording_at)}</Row>
            <Row label="Platform">
              {user.platform || "—"} {user.app_version ? `· ${user.app_version}` : ""}
            </Row>
            <Row label="Reports">{user.feedback_count}</Row>
            {note ? <Row label="Note">{note}</Row> : null}
          </tbody>
        </table>
      </div>

      <div className="card section">
        <h2>Plan</h2>
        <p className="muted small">
          Granted by hand — there is no purchase flow yet. Pro lifts the Free plan's limits on
          recording length, voice memories per month, typed-memory length and journals, and the
          server enforces whichever plan is set here from the user's next request. Pro is stored
          as the <span className="mono">premium</span> tier.
        </p>
        <div className="toolbar">
          <span className={`pill ${isPro ? "premium" : ""}`}>{isPro ? "Pro" : "Free"}</span>
          <button
            disabled={busy}
            className={isPro ? "" : "primary"}
            onClick={() => setPlan(!isPro)}
          >
            {isPro ? "Move back to Free" : "Upgrade to Pro"}
          </button>
        </div>
        {actionError ? <p className="error small">{actionError}</p> : null}
        {detail.data.tier_updated_by ? (
          <p className="muted small">
            Last changed by {detail.data.tier_updated_by} {fmtWhen(detail.data.tier_updated_at)}.
          </p>
        ) : null}
      </div>

      <div className="card section">
        <h2>Maintenance</h2>
        <div className="toolbar">
          <button disabled={busy} onClick={() => run(() => api.recomputeStats(uid))}>
            Recompute counters
          </button>
          <button disabled={busy} className="danger" onClick={purge}>
            Delete account…
          </button>
        </div>
      </div>

      <div className="section">
        <h2>Devices</h2>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th className="plain">Install id</th>
                <th className="plain">Platform</th>
                <th className="plain">Accounts</th>
                <th className="plain">Last seen</th>
              </tr>
            </thead>
            <tbody>
              {devices.map((d) => (
                <tr
                  key={d.install_id}
                  onClick={() => navigate(`/devices/${encodeURIComponent(d.install_id)}`)}
                >
                  <td className="mono">
                    <a>{d.install_id}</a>
                  </td>
                  <td>
                    {d.platform || "—"} {d.app_version}
                  </td>
                  <td>
                    {d.account_count > 1 ? (
                      <span className="pill warn">{d.account_count} accounts</span>
                    ) : (
                      d.account_count
                    )}
                  </td>
                  <td>{fmtWhen(d.last_seen_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {!devices.length ? <Empty>No device has reported in for this account.</Empty> : null}
        </div>
      </div>

      <div className="section">
        <h2>Recent recordings</h2>
        <p className="muted small">
          Metadata only. Transcripts, titles and audio are never sent to this console.
        </p>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th className="plain">Date</th>
                <th className="plain">Length</th>
                <th className="plain">Status</th>
                <th className="plain">Language</th>
              </tr>
            </thead>
            <tbody>
              {recent_recordings.map((r) => (
                <tr key={r.id}>
                  <td>{fmtDate(r.event_date)}</td>
                  <td>{fmtDuration(r.duration_sec)}</td>
                  <td>
                    <StatusPill status={r.status} />
                  </td>
                  <td>{r.language || "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {!recent_recordings.length ? <Empty>Nothing recorded yet.</Empty> : null}
        </div>
      </div>
    </>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <tr>
      <th className="plain" style={{ width: 150 }}>
        {label}
      </th>
      <td className="wrap">{children}</td>
    </tr>
  );
}
