/** Firebase sign-in for the console.
 *
 * Google specifically, and not email/password: the backend's admin allowlist
 * requires `email_verified` on the token, because Firebase's email/password
 * provider will happily issue a token for any address the caller types. Google
 * returns an address it has actually verified.
 *
 * Being a static, publicly-served page is fine. There is no secret here — the
 * Firebase web config is designed to be public, and every authorization
 * decision is made server-side by `require_admin`.
 */

import { initializeApp } from "firebase/app";
import {
  GoogleAuthProvider,
  getAuth,
  onAuthStateChanged,
  signInWithPopup,
  signOut,
  type User,
} from "firebase/auth";

const config = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
};

export const configured = Boolean(config.apiKey && config.projectId && config.appId);

const app = configured ? initializeApp(config) : null;
const auth = app ? getAuth(app) : null;

export function watchUser(cb: (user: User | null) => void): () => void {
  if (!auth) {
    cb(null);
    return () => {};
  }
  return onAuthStateChanged(auth, cb);
}

export async function signIn(): Promise<void> {
  if (!auth) throw new Error("Firebase is not configured");
  await signInWithPopup(auth, new GoogleAuthProvider());
}

export async function signOutAdmin(): Promise<void> {
  if (auth) await signOut(auth);
}

/** A fresh ID token for the current user, or null when signed out.
 *
 * Fetched per request rather than cached: tokens expire after an hour, and the
 * SDK refreshes transparently, so asking each time is both correct and cheap.
 */
export async function idToken(): Promise<string | null> {
  const user = auth?.currentUser;
  return user ? user.getIdToken() : null;
}
