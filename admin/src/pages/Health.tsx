import { api } from "../api";
import {
  Empty,
  ErrorBox,
  Loading,
  StatusPill,
  fmtDate,
  fmtDuration,
  fmtWhen,
  useAsync,
} from "../components";

export function Health() {
  const failed = useAsync(() => api.failedRecordings(), []);
  const audit = useAsync(() => api.audit(), []);

  return (
    <>
      <h1>Health</h1>

      <div className="section">
        <h2>Stuck or failed ingestion</h2>
        <p className="muted small">
          Recordings that failed to transcribe, or that have been mid-transcription long enough to
          look stuck. Nobody is told when this happens — the user just sees a memory whose
          transcript never arrives — so this list is the only warning there is.
        </p>
        {failed.error ? <ErrorBox error={failed.error} /> : null}
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th className="plain">Date</th>
                <th className="plain">Length</th>
                <th className="plain">Status</th>
                <th className="plain">Recording</th>
              </tr>
            </thead>
            <tbody>
              {failed.data?.map((r) => (
                <tr key={r.id}>
                  <td>{fmtDate(r.event_date)}</td>
                  <td>{fmtDuration(r.duration_sec)}</td>
                  <td>
                    <StatusPill status={r.status} />
                  </td>
                  <td className="mono small">{r.id}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {failed.loading ? <Loading /> : null}
          {!failed.loading && failed.data && !failed.data.length ? (
            <Empty>Nothing stuck. The pipeline is keeping up.</Empty>
          ) : null}
        </div>
      </div>

      <div className="section">
        <h2>Admin activity</h2>
        <p className="muted small">
          Every tier change and deletion made from this console, and who made it.
        </p>
        {audit.error ? <ErrorBox error={audit.error} /> : null}
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th className="plain">When</th>
                <th className="plain">Admin</th>
                <th className="plain">Action</th>
                <th className="plain">Target</th>
                <th className="plain">Detail</th>
              </tr>
            </thead>
            <tbody>
              {audit.data?.items.map((e) => (
                <tr key={e.id}>
                  <td>{fmtWhen(e.at)}</td>
                  <td>{e.admin_email || e.admin_uid}</td>
                  <td>{e.action}</td>
                  <td className="mono small">{e.target}</td>
                  <td>{e.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {audit.loading ? <Loading /> : null}
          {!audit.loading && audit.data && !audit.data.items.length ? (
            <Empty>No admin actions recorded.</Empty>
          ) : null}
        </div>
      </div>
    </>
  );
}
