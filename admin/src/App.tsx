import { useEffect, useState } from "react";
import type { User } from "firebase/auth";
import { configured, signIn, signOutAdmin, watchUser } from "./auth";
import { Overview } from "./pages/Overview";
import { Users } from "./pages/Users";
import { UserDetail } from "./pages/UserDetail";
import { DeviceDetail, Devices } from "./pages/Devices";
import { Feedback } from "./pages/Feedback";
import { Health } from "./pages/Health";
import { navigate, param, useRoute } from "./router";

const NAV = [
  { path: "/", label: "Overview" },
  { path: "/users", label: "People" },
  { path: "/devices", label: "Devices" },
  { path: "/feedback", label: "Reports" },
  { path: "/health", label: "Health" },
];

export function App() {
  const route = useRoute();
  const [user, setUser] = useState<User | null>(null);
  const [ready, setReady] = useState(false);
  const [signInError, setSignInError] = useState<string | null>(null);

  useEffect(
    () =>
      watchUser((u) => {
        setUser(u);
        setReady(true);
      }),
    [],
  );

  if (!configured) {
    return (
      <div className="center">
        <div className="card" style={{ maxWidth: 520 }}>
          <h1>Not configured</h1>
          <p>
            Set <code>VITE_FIREBASE_API_KEY</code>, <code>VITE_FIREBASE_AUTH_DOMAIN</code>,{" "}
            <code>VITE_FIREBASE_PROJECT_ID</code> and <code>VITE_FIREBASE_APP_ID</code> in{" "}
            <code>admin/.env.local</code>, then restart the dev server.
          </p>
          <p className="muted small">
            These come from a <strong>web</strong> app registered in the Firebase project. The
            existing registration is for Android only, so a new one is needed.
          </p>
        </div>
      </div>
    );
  }

  if (!ready) return <div className="center">Loading…</div>;

  if (!user) {
    return (
      <div className="center">
        <div className="card" style={{ maxWidth: 420 }}>
          <div className="brand" style={{ justifyContent: "center" }}>
            <span className="mark" />
            MemoriesIQ Admin
          </div>
          <p className="muted">
            Sign in with a Google account that is on the admin allowlist.
          </p>
          <button
            className="primary"
            onClick={() =>
              signIn().catch((e) => setSignInError(e instanceof Error ? e.message : String(e)))
            }
          >
            Sign in with Google
          </button>
          {signInError ? <p className="error small">{signInError}</p> : null}
        </div>
      </div>
    );
  }

  return (
    <div className="shell">
      <nav className="sidebar">
        <div className="brand">
          <span className="mark" />
          MemoriesIQ
        </div>
        {NAV.map((item) => (
          <a
            key={item.path}
            className={isActive(route, item.path) ? "active" : ""}
            onClick={() => navigate(item.path)}
          >
            {item.label}
          </a>
        ))}
        <div className="spacer" />
        <div className="who">{user.email}</div>
        <button onClick={() => signOutAdmin()}>Sign out</button>
      </nav>
      <main>
        <Page route={route} />
      </main>
    </div>
  );
}

function isActive(route: string, path: string): boolean {
  if (path === "/") return route === "/";
  return route === path || route.startsWith(`${path}/`);
}

function Page({ route }: { route: string }) {
  const uid = param(route, "/users/");
  if (uid) return <UserDetail uid={uid} />;

  const installId = param(route, "/devices/");
  if (installId) return <DeviceDetail installId={installId} />;

  switch (route) {
    case "/users":
      return <Users />;
    case "/devices":
      return <Devices />;
    case "/feedback":
      return <Feedback />;
    case "/health":
      return <Health />;
    default:
      return <Overview />;
  }
}
