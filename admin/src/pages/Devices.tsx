import { useState } from "react";
import { api } from "../api";
import { Empty, ErrorBox, Loading, displayName, fmtWhen, useAsync } from "../components";
import { navigate } from "../router";

export function Devices() {
  const [cursors, setCursors] = useState<(string | null)[]>([null]);
  const cursor = cursors[cursors.length - 1];
  const page = useAsync(() => api.devices({ limit: 50, cursor }), [cursor]);

  return (
    <>
      <h1>Devices</h1>
      <p className="muted small">
        One row per installation. A device keeps its id across sign-out, so when someone switches
        accounts on the same phone every account they used shows up together here.
      </p>

      {page.error ? <ErrorBox error={page.error} /> : null}

      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th className="plain">Install id</th>
              <th className="plain">Platform</th>
              <th className="plain">App version</th>
              <th className="plain">Accounts</th>
              <th className="plain">First seen</th>
              <th className="plain">Last seen</th>
            </tr>
          </thead>
          <tbody>
            {page.data?.items.map((d) => (
              <tr
                key={d.install_id}
                onClick={() => navigate(`/devices/${encodeURIComponent(d.install_id)}`)}
              >
                <td className="mono">
                  <a>{d.install_id}</a>
                </td>
                <td>{d.platform || "—"}</td>
                <td>{d.app_version || "—"}</td>
                <td>
                  {d.account_count > 1 ? (
                    <span className="pill warn">{d.account_count}</span>
                  ) : (
                    d.account_count
                  )}
                </td>
                <td>{fmtWhen(d.first_seen_at)}</td>
                <td>{fmtWhen(d.last_seen_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {page.loading ? <Loading /> : null}
        {!page.loading && page.data && !page.data.items.length ? (
          <Empty>No devices have reported in yet.</Empty>
        ) : null}
      </div>

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

export function DeviceDetail({ installId }: { installId: string }) {
  const detail = useAsync(() => api.device(installId), [installId]);

  if (detail.error) return <ErrorBox error={detail.error} />;
  if (detail.loading || !detail.data) return <Loading />;

  const { device, accounts } = detail.data;

  return (
    <>
      <p className="small">
        <a onClick={() => navigate("/devices")}>← Devices</a>
      </p>
      <h1 className="mono">{device.install_id}</h1>
      <p className="muted">
        {device.platform || "unknown platform"} · {device.app_version || "unknown version"} · first
        seen {fmtWhen(device.first_seen_at)} · last seen {fmtWhen(device.last_seen_at)}
      </p>

      <div className="section">
        <h2>
          Accounts used on this device{" "}
          {accounts.length > 1 ? <span className="pill warn">{accounts.length}</span> : null}
        </h2>
        {accounts.length > 1 ? (
          <p className="muted small">
            Several accounts share this phone. That is expected when someone signs out and back in
            with a different email — it is not evidence of anything wrong.
          </p>
        ) : null}
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th className="plain">Person</th>
                <th className="plain">uid</th>
                <th className="plain">First seen</th>
                <th className="plain">Last seen</th>
              </tr>
            </thead>
            <tbody>
              {accounts.map((a) => (
                <tr key={a.uid} onClick={() => navigate(`/users/${encodeURIComponent(a.uid)}`)}>
                  <td>
                    <a>{displayName(a)}</a>
                  </td>
                  <td className="mono small">{a.uid}</td>
                  <td>{fmtWhen(a.first_seen_at)}</td>
                  <td>{fmtWhen(a.last_seen_at)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {!accounts.length ? <Empty>No accounts recorded for this device.</Empty> : null}
        </div>
      </div>
    </>
  );
}
