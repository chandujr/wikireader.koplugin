# AGENTS.md — WikiReader

## What this is

A KOReader plugin (Lua, `.koplugin`) that reads Wikipedia articles as
reflowable EPUBs. It fetches the raw Parsoid HTML from the MediaWiki API,
strips/transforms everything that doesn't survive reflow (media, infobox
clutter, flexbox layouts, cladograms, formulas), then delegates EPUB
building to KOReader's own `ui/wikipedia.lua` (`Wikipedia.createEpub`).
Articles are cached as real EPUB files (10 files, 24 h). Settings live in
KOReader's `G_reader_settings` under `wikireader_*`.

## Files — which one to touch

| File | Role |
|---|---|
| `main.lua` | Plugin entry point: menus, search/featured/category browsing, link handler, back-history nav, refetch/save/share/clear-cache actions. Start here for any UI or user-facing behavior change. |
| `epub.lua` | Orchestrates article → EPUB: monkey-patches `Wikipedia` + `Archiver` hooks, sets per-feature HTML-cleaning options, injects stylesheet + metadata. Change here to alter the fetch/build pipeline or which passes run. |
| `htmlclean.lua` | All HTML transformations: strip clutter (navboxes, hatnotes, timeline bars), unwrap article links, drop/keep infobox media cells, center infobox cells, border infobox/wikitable tables, merge quote attributions, rewrite `{{Multiple image}}` flexbox to tables. |
| `qrimage.lua` | Replaces each boxed image with a QR code of its File: page (renders QR via KOReader's `ffi/qrencode`, writes minimal PNGs, rewrites image boxes to placeholder `<img>`s). Also owns the shared image-box walker used by the lazy-image mode; drops non-image media (video/audio). |
| `latex.lua` | Math formulas: block formulas → fetched Wikipedia SVGs (cap 60, Unicode fallback), inline formulas → Unicode transcription (replaces `MathML`/images). |
| `cladogram.lua` | Clade tables → ASCII tree `<pre>` diagrams. |
| `wikiutil.lua` | Shared helpers: minimal HTTP JSON GET, Wikipedia URL parsing/encoding, HTML notice-tag constants, balanced-tag matching (`findMatchingClose`). |
| `wikireader-cache.lua` | EPUB cache (10 entries / 24 h), stale-file removal, sidecar-aware delete, cache dir handling. |
| `wikireader-history.lua` | Last-10-articles reading history (title/lang references persisted in `G_reader_settings`, no files). |
| `wikireader-bookmarks.lua` | User-bookmarked articles (max 50, newest first), stored as title/lang references in `G_reader_settings` (`wikireader_bookmarks`); never evicts automatically, only via explicit remove/clear. |
| `lazyfetch.lua` | Position-windowed background buffering for "Fetch images in background": downloads the URLs listed in an EPUB's `OEBPS/wikireader-pending.json` (only images near the reading position — sections are mapped to pages via the document TOC, window = pos−3..pos+10 pages, re-checked every 20 s), rewrites the zip in place (`.tmp` + rename), keeps the pending entry until nothing remains, and seamlessly reloads the open document after each batch. |
| `categories.lua` | Featured-articles category tree built from the API's flat section list; module-level lookup used by the link handler. |
| `mainpage.lua` | Scrapes today's English Wikipedia main page for its "In the news" / "Did you know" / "On this day" boxes (by their stable `mp-*` ids), cleans them, and absolutizes the article links. English-only: other wikis have different main-page titles and id-less markup. |
| `_meta.lua` | Plugin name/version metadata shown in the About dialog. |

## Data flow (one pass each, order matters)

1. `main.lua` resolves title/lang → `epub.buildEpub`.
2. `epub.lua` checks cache → fetches Parsoid HTML from the MediaWiki API.
3. HTML cleaning passes run in sequence (`htmlclean`, `latex`, `cladogram`,
   QR or lazy-image placeholders via `qrimage`); `latex` also fetches
   block-formula SVGs (capped, Unicode fallback on failure).
4. `Wikipedia.createEpub` builds the EPUB; patched `Archiver` hooks inject
   QR PNGs, block-formula math SVGs, stylesheet, metadata.
5. Result cached as `<lang> - <Title>.epub`; opened via ReaderUI.
6. In lazy-image mode, `lazyfetch` then buffers images around the reading
   position in the background (zip swap + seamless reload per batch).

The "Wikipedia main page" flow skips steps 2–4: `mainpage.fetchSections`
scrapes and cleans the three main-page boxes itself, and
`epub.buildMainPageEpub` writes the EPUB directly via the shared
`writeSinglePageEpub` writer (also used by the search/category builders).
Its cache key embeds the date (`__mainpage__<date>`), so a copy never
outlives the day's news.

## Commenting strategy

- Comments explain **why**, never **what**. No comment should restate the
  function name, narrate the next line, or label a section the code already
  shows.
- When adding code, add a `why`-comment only where the code alone can't be
  understood. When editing, condense verbose comments rather than growing
  them — but never delete rationale-bearing content.
- Add comments **only if necessary** (important). I repeat, do not add comments unnecessarily.

## Notes for LLMs

- Lua 5.1-compatible; no external dependencies beyond KOReader's runtime.
- `nav_history`/`nav_current` in `main.lua` are module-level on purpose
  (KOReader rebuilds plugin instances per UI) — do not move them to `self`.
- Validate edits with `luac -p <file>`; no test suite exists.
- Find the local koreader codebase using `find / -name "*wikipedia.lua*" 2>/dev/null` in case you need to consult koreader scripts.