# MemoriesIQ marketing site

Hand-written static HTML and CSS. No build step, no toolchain, no dependencies.

That is deliberate rather than lazy: this page exists to convert paid-ad clicks, so it has to render
immediately on a phone over a mobile connection. A client-rendered framework would cost both SEO and
the Core Web Vitals that feed ad quality scores, in exchange for conveniences a five-section page
does not need. (The admin console *is* React — different job, different trade.)

```
index.html     hero · features · how it works · privacy · FAQ · CTA
privacy.html   REQUIRED before the app can be listed on Google Play
terms.html
styles.css     one file, theme-aware via prefers-color-scheme
```

## Before publishing

- **Fill in every `[BRACKETED]` placeholder** in `privacy.html` and `terms.html` — legal entity,
  registered address, contact address, governing jurisdiction. They are left visible on purpose so
  the pages cannot be shipped half-finished. Have both reviewed by a lawyer.
- Replace `hello@memoriesiq.com` in `index.html` with a mailbox you actually read.
- The privacy policy describes what the system genuinely does today: audio encrypted at rest under a
  dedicated key, transcription and answering via Gemini on Vertex AI, sign-in codes sent through
  Azure Communication Services, an install identifier that is not a hardware id, and deletion that
  really removes the audio. **If the system changes, change the policy** — an inaccurate privacy
  policy is worse than none.
- The copy deliberately does not promise specific language support. Cross-lingual recall is the real
  differentiator, but `docs/milestones.md` still records it as unverified against non-English audio;
  claim it once it has been tested.

## Preview and deploy

```bash
firebase emulators:start --only hosting     # from the repo root
firebase deploy --only hosting:site --project voiceiq-505205
```
