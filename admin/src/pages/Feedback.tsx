import { useState } from "react";
import { api } from "../api";
import { Empty, ErrorBox, Loading, StatusPill, fmtWhen, useAsync } from "../components";
import { navigate } from "../router";

const STATUSES = ["new", "open", "resolved", "wontfix"];

export function Feedback() {
  const [kind, setKind] = useState("");
  const [cursors, setCursors] = useState<(string | null)[]>([null]);
  const cursor = cursors[cursors.length - 1];
  const page = useAsync(
    () => api.feedback({ limit: 50, cursor, kind: kind || null }),
    [cursor, kind],
  );

  async function setStatus(id: string, status: string) {
    await api.triage(id, { status });
    page.reload();
  }

  return (
    <>
      <h1>Reports</h1>
      <p className="muted small">
        What users wrote in "report a problem", across every account. Errors inside the app are only
        ever transmitted when someone files a report, so this is the crash channel as well as the
        suggestion box.
      </p>

      <div className="toolbar">
        <select
          value={kind}
          onChange={(e) => {
            setKind(e.target.value);
            setCursors([null]);
          }}
        >
          <option value="">All kinds</option>
          <option value="problem">Problems</option>
          <option value="idea">Ideas</option>
          <option value="other">Other</option>
        </select>
      </div>

      {page.error ? <ErrorBox error={page.error} /> : null}
      {page.loading ? <Loading /> : null}

      {page.data?.items.map((item) => (
        <div className="card section" key={item.id} style={{ marginTop: 14 }}>
          <div className="toolbar" style={{ marginBottom: 8 }}>
            <span className="pill">{item.kind}</span>
            <StatusPill status={item.status} />
            <span className="muted small">
              {fmtWhen(item.created_at)} · {item.platform || "unknown"} ·{" "}
              {item.app_version || "unknown version"}
            </span>
            <span className="spacer" style={{ flex: 1 }} />
            <a onClick={() => navigate(`/users/${encodeURIComponent(item.uid)}`)}>view account</a>
          </div>

          <p style={{ color: "var(--ink)" }}>{item.message}</p>

          {item.diagnostics ? (
            <details>
              <summary className="muted small">Diagnostics</summary>
              <pre className="diag">{item.diagnostics}</pre>
            </details>
          ) : null}

          <div className="toolbar" style={{ marginTop: 10, marginBottom: 0 }}>
            {STATUSES.map((s) => (
              <button
                key={s}
                disabled={s === item.status}
                onClick={() => setStatus(item.id, s)}
                className={s === "resolved" ? "primary" : ""}
              >
                {s}
              </button>
            ))}
          </div>
          {item.admin_note ? <p className="muted small">Note: {item.admin_note}</p> : null}
        </div>
      ))}

      {!page.loading && page.data && !page.data.items.length ? (
        <Empty>Nothing reported yet.</Empty>
      ) : null}

      <div className="pager">
        <button disabled={cursors.length === 1} onClick={() => setCursors(cursors.slice(0, -1))}>
          Back
        </button>
        <button
          disabled={!page.data?.next_cursor}
          onClick={() => setCursors([...cursors, page.data!.next_cursor])}
        >
          Next
        </button>
      </div>
    </>
  );
}
