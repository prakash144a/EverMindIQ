import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { api } from "../api";
import { ErrorBox, Loading, Stat, fmtDuration, useAsync } from "../components";

export function Overview() {
  const summary = useAsync(() => api.overview(), []);
  const recordings = useAsync(() => api.timeseries("recordings", 30), []);
  const actives = useAsync(() => api.timeseries("active_users", 30), []);
  const histogram = useAsync(() => api.histogram(), []);

  if (summary.error) return <ErrorBox error={summary.error} />;
  if (summary.loading || !summary.data) return <Loading />;

  const s = summary.data;

  return (
    <>
      <h1>Overview</h1>

      <div className="grid">
        <Stat
          label="People"
          value={s.users_total}
          hint={`${s.users_with_email} registered · ${s.users_anonymous} anonymous`}
        />
        <Stat
          label="Active (7d)"
          value={s.active_7d}
          hint={`${s.active_1d} today · ${s.active_30d} in 30d`}
        />
        <Stat
          label="Premium"
          value={s.users_premium}
          hint={`${s.users_total - s.users_premium} on free`}
        />
        <Stat
          label="Recordings"
          value={s.recordings_total}
          hint={`${fmtDuration(s.total_duration_sec)} captured`}
        />
        <Stat
          label="Longest recording"
          value={fmtDuration(s.max_duration_sec)}
          hint="longest ever made"
        />
        <Stat
          label="Devices"
          value={s.devices_total}
          hint={
            s.multi_account_devices
              ? `${s.multi_account_devices} with more than one account`
              : "one account each"
          }
        />
        <Stat label="Reports" value={s.feedback_total} hint="problem reports and ideas" />
        <Stat
          label="Failed ingests"
          value={s.failed_recordings}
          hint={s.failed_recordings ? "needs attention" : "pipeline healthy"}
        />
      </div>

      <div className="section">
        <h2>Recordings per day</h2>
        <div className="card chart">
          {recordings.data ? <DailyArea points={recordings.data.points} /> : <Loading />}
        </div>
      </div>

      <div className="section">
        <h2>Active people per day</h2>
        <div className="card chart">
          {actives.data ? <DailyArea points={actives.data.points} /> : <Loading />}
        </div>
      </div>

      <div className="section">
        <h2>How long people record</h2>
        <p className="muted small">
          The question behind "what length do users expect" is really about the shape of this
          distribution — a single maximum only ever describes one outlier. Percentiles are
          interpolated from these buckets, so they are approximate; the longest recording is exact.
        </p>
        <div className="card chart">
          {histogram.data ? (
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={histogram.data.buckets}>
                <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                <XAxis dataKey="label" stroke="var(--muted)" fontSize={12} />
                <YAxis allowDecimals={false} stroke="var(--muted)" fontSize={12} />
                <Tooltip
                  contentStyle={{
                    background: "var(--surface)",
                    border: "1px solid var(--border)",
                    borderRadius: 8,
                  }}
                />
                <Bar dataKey="count" fill="var(--violet)" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          ) : (
            <Loading />
          )}
        </div>
        {histogram.data ? (
          <p className="muted small">
            {histogram.data.total} recordings · p50 ≈ {fmtDuration(histogram.data.p50_approx)} · p90
            ≈ {fmtDuration(histogram.data.p90_approx)} · longest{" "}
            {fmtDuration(histogram.data.max_duration_sec)}
          </p>
        ) : null}
      </div>
    </>
  );
}

function DailyArea({ points }: { points: { day: string; value: number }[] }) {
  if (!points.length) return <div className="empty">No data in the last 30 days.</div>;
  return (
    <ResponsiveContainer width="100%" height="100%">
      <AreaChart data={points}>
        <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
        <XAxis dataKey="day" stroke="var(--muted)" fontSize={12} />
        <YAxis allowDecimals={false} stroke="var(--muted)" fontSize={12} />
        <Tooltip
          contentStyle={{
            background: "var(--surface)",
            border: "1px solid var(--border)",
            borderRadius: 8,
          }}
        />
        <Area
          type="monotone"
          dataKey="value"
          stroke="var(--violet)"
          fill="var(--violet)"
          fillOpacity={0.18}
        />
      </AreaChart>
    </ResponsiveContainer>
  );
}
