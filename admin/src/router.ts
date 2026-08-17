/** Hash routing, hand-rolled.
 *
 * Seven pages and no nested layouts do not justify a routing dependency, and
 * hash routes mean Firebase Hosting needs no rewrite rule to avoid 404s on a
 * deep link.
 */

import { useEffect, useState } from "react";

export function useRoute(): string {
  const [route, setRoute] = useState(() => window.location.hash.slice(1) || "/");
  useEffect(() => {
    const onChange = () => setRoute(window.location.hash.slice(1) || "/");
    window.addEventListener("hashchange", onChange);
    return () => window.removeEventListener("hashchange", onChange);
  }, []);
  return route;
}

export function navigate(path: string): void {
  window.location.hash = path;
}

/** Match "/users/:uid" style paths, returning the trailing segment. */
export function param(route: string, prefix: string): string | null {
  if (!route.startsWith(prefix)) return null;
  const rest = route.slice(prefix.length);
  return rest ? decodeURIComponent(rest) : null;
}
