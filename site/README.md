# MemoriesIQ marketing site

Hand-written static HTML and CSS. No build step, no toolchain, no dependencies — and no image
files: every illustration on the page is CSS and inline SVG, so the whole site is two requests.
That includes the favicon and the header mark, which are the app icon inlined as a data URI rather
than a linked file — **do not hand-edit either**; they come from
`tools/branding/generate_icons.py`, which prints the URI it wants inlined and writes the Android
and web icons from the same geometry. That script is the only reason the header, the favicon and
the Play listing cannot drift apart.

That is deliberate rather than lazy: this page exists to convert paid-ad clicks, so it has to render
immediately on a phone over a mobile connection. A client-rendered framework would cost both SEO and
the Core Web Vitals that feed ad quality scores, in exchange for conveniences a page this size does
not need. (The admin console *is* React — different job, different trade.)

```
index.html      hero · the forgetting panel · four feature showcases ·
                how it works · pricing · privacy · FAQ · CTA
privacy.html    REQUIRED before the app can be listed on Google Play
terms.html
styles.v3.css   one file, theme-aware via prefers-color-scheme
```

## The illustrations

The phone mockups are **markup, not screenshots**: a `.phone` frame wrapping a `.screen` built from
the same parts the app uses (`.seg` for Write/Speak, `.orb`, `.wave`, `.bubble`, `.memcard`). That
costs nothing to download, stays sharp at any pixel density, and follows the visitor's colour
scheme. It also means they drift from the real app silently — **when a screen changes in
`app/lib/src/features/`, check the matching mockup here**, because nothing will fail if you don't.

Colours are copied from `app/lib/src/core/tokens.dart`. Keep the two in step; sage, gold and the
immersive capture gradient are the whole brand.

Everything animates for feel and nothing animates for meaning, so `prefers-reduced-motion` switches
all of it off in one rule at the bottom of the stylesheet. Keep it that way.

Stylesheet filenames are versioned (`styles.v3.css`) because hosting serves CSS `immutable` for a
year — a redesign needs a new URL or returning visitors keep the old one.

## Pricing and the store badges

The two plans in `#pricing` are not marketing invention — they are the entitlements the backend
actually enforces, in `backend/app/core/entitlements.py` and the `VOICEIQ_TEXT_MAX_CHARS_*` /
`VOICEIQ_JOURNALS_MAX_*` settings. **If those numbers move, move them here too**; a pricing table
that disagrees with the server is the one piece of copy on this site that can lose a chargeback.
Anything premium does *not* do yet carries a **Soon** chip instead of a tick, and must keep it
until it ships. A blank cell means no — it is left genuinely empty rather than crossed out, with
the "not included" carried in a `.sr-only` span so the table still reads correctly aloud.

$4.99/mo · $39/yr is announced but not sellable: there is no purchase flow anywhere in the product,
so both plan buttons are inert `<span>`s rather than links. Same for the Play and App Store badges —
neither listing exists, so they are spans that say "coming soon" instead of anchors that 404. Turn
them into real links only when the listings are live.

## Before publishing

- **Fill in every `[BRACKETED]` placeholder** in `privacy.html` and `terms.html` — legal entity,
  registered address, contact address, governing jurisdiction. They are left visible on purpose so
  the pages cannot be shipped half-finished. Have both reviewed by a lawyer.
- Check the contact address in `index.html` is a mailbox you actually read.
- The privacy policy describes what the system genuinely does today: audio encrypted at rest under a
  dedicated key, transcription and answering via Gemini on Vertex AI, sign-in codes sent through
  Azure Communication Services, an install identifier that is not a hardware id, and deletion that
  really removes the audio. **If the system changes, change the policy** — an inaccurate privacy
  policy is worse than none.
- The copy deliberately does not promise specific language support. Cross-lingual recall is the real
  differentiator, but `docs/milestones.md` still records it as unverified against non-English audio;
  claim it once it has been tested.

## Preview and deploy

Hosted on **Azure Static Web Apps** (`memoriesiq-web`, resource group `rg-nativemindsai-web`),
served at <https://memoriesiq.nativemindsai.com> — a subdomain of the company site, whose DNS zone
lives in the same resource group. It sits beside the backend on GCP rather than with it because the
marketing site shares a domain with the company site, not with the product.

There is no CI for this folder: the app's own pipeline has nothing to say about a static page, and
this deploys in seconds by hand.

```bash
python -m http.server 5000 --directory site        # preview → http://127.0.0.1:5000

TOKEN=$(az staticwebapp secrets list --name memoriesiq-web \n  --resource-group rg-nativemindsai-web --query "properties.apiKey" -o tsv)
npx --yes @azure/static-web-apps-cli deploy ./site --deployment-token "$TOKEN" --env production
```

`staticwebapp.config.json` carries the caching and security headers (CSS immutable for a year, HTML
for five minutes — which is why the stylesheet filename is versioned). Canonical URLs in all three
pages point at the live domain; if this ever moves to its own domain, they move with it or search
engines will keep indexing the old address.
