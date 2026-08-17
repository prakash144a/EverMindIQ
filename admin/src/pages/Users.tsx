import { useState } from "react";
import { api } from "../api";
import {
  Empty,
  ErrorBox,
  Loading,
  displayName,
  fmtDuration,
  fmtWhen,
  useAsync,
} from "../components";
import { navigate } from "../router";
import { SORTABLE, type SortField } from "../types";

const COLUMNS: { key: SortField | null; label: string }[] = [
  { key: "email", label: "Person" },
  { key: null, label: "Install id" },
  { key: null, label: "Tier" },
  { key: "recordings_count", label: "Recordings" },
  { key: "max_duration_sec", label: "Longest" },
  { key: "total_duration_sec", label: "Total" },
  { key: "last_active_at", label: "Last active" },
  { key: "created_at", label: "Joined" },
];

export function Users() {
  const [sort, setSort] = useState<SortField>("last_active_at");
  const [order, setOrder] = useState<"asc" | "desc">("desc");
  const [tier, setTier] = useState("");
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  // A stack, so "Back" returns to the previous page. Cursor paging is
  // forward-only by nature: there is no "page N" to jump to.
  const [cursors, setCursors] = useState<(string | null)[]>([null]);

  const cursor = cursors[cursors.length - 1];
  const page = useAsync(
    () => api.users({ limit: 50, cursor, sort, order, tier: tier || null, q: query || null }),
    [cursor, sort, order, tier, query],
  );
  const total = useAsync(() => api.userCount(), []);

  function toggleSort(key: SortField) {
    if (key === sort) setOrder(order === "desc" ? "asc" : "desc");
    else setSort(key);
    setCursors([null]);
  }

  function runSearch(value: string) {
    setQuery(value);
    setCursors([null]);
  }

  return (
    <>
      <h1>People {total.data ? <span className="muted">({total.data.value})</span> : null}</h1>

      <div className="toolbar">
        <input
          placeholder="email, name or uid — starts with…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") runSearch(search);
          }}
          style={{ minWidth: 260 }}
        />
        <button onClick={() => runSearch(search)}>Search</button>
        {query ? (
          <button
            onClick={() => {
              setSearch("");
              runSearch("");
            }}
          >
            Clear
          </button>
        ) : null}
        <select
          value={tier}
          onChange={(e) => {
            setTier(e.target.value);
            setCursors([null]);
          }}
        >
          <option value="">All tiers</option>
          <option value="free">Free</option>
          <option value="premium">Premium</option>
        </select>
      </div>

      {query ? (
        <p className="muted small">
          Prefix match only — the datastore has no substring search. Results are ordered by{" "}
          {page.data?.sorted_by ?? "email"}, because a search fixes the sort field.
        </p>
      ) : null}

      {page.error ? <ErrorBox error={page.error} /> : null}

      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              {COLUMNS.map((col) => (
                <th
                  key={col.label}
                  className={col.key && SORTABLE.includes(col.key) ? "" : "plain"}
                  onClick={col.key ? () => toggleSort(col.key as SortField) : undefined}
                >
                  {col.label}
                  {col.key === sort ? (order === "desc" ? " ↓" : " ↑") : ""}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {page.data?.items.map((u) => (
              <tr key={u.uid} onClick={() => navigate(`/users/${encodeURIComponent(u.uid)}`)}>
                <td>
                  <a>{displayName(u)}</a>
                  <div className="muted mono small">{u.uid}</div>
                </td>
                <td className="mono">{u.install_id ? u.install_id.slice(0, 12) : "—"}</td>
                <td>
                  {u.tier === "premium" ? (
                    <span className="pill premium">premium</span>
                  ) : (
                    <span className="pill">free</span>
                  )}
                </td>
                <td>{u.recordings_count}</td>
                <td>{fmtDuration(u.max_duration_sec)}</td>
                <td>{fmtDuration(u.total_duration_sec)}</td>
                <td>{fmtWhen(u.last_active_at)}</td>
                <td>{fmtWhen(u.created_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {page.loading ? <Loading /> : null}
        {!page.loading && page.data && !page.data.items.length ? (
          <Empty>No accounts match.</Empty>
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
        <span className="muted small">page {cursors.length}</span>
      </div>
    </>
  );
}
