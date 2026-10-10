# AGENTS.md — WikiReader

## What this is

A KOReader plugin (Lua, `.koplugin`) that reads Wikipedia articles as
reflowable EPUBs. It fetches the raw Parsoid HTML from the MediaWiki API,
strips/transforms everything that doesn't survive reflow (media, infobox
clutter, flexbox layouts, cladograms, formulas), then delegates EPUB
building to KOReader's own `ui/wikipedia.lua` (`Wikipedia.createEpub`).
Articles are cached as real EPUB files (10 files, 24 h). Settings live in
KOReader's `G_reader_settings` under `wikireader_*`; image handling is one
setting, `wikireader_show_images` (default on): images lazy-fetch in the
background at high quality (thumb rewritten up to 4x the rendered width,
clamped to the original file size, srcset 2x/1.5x as fallback) while off
drops them entirely for a text-only read.

## Files — which one to touch

| File | Role |
|---|---|
| `main.lua` | Plugin entry point: menus, search/featured/category browsing, link handler, back-history nav, hold-on-image full-screen caption viewer (decodes epub.lua's sentinel caption links), refetch/save/share/clear-cache actions. Start here for any UI or user-facing behavior change. |
| `epub.lua` | Orchestrates article → EPUB: monkey-patches `Wikipedia` + `Archiver` hooks, sets per-feature HTML-cleaning options, injects stylesheet + metadata, and wraps each captioned image in a sentinel link whose URL carries the caption (decoded by main.lua's hold hook for the full-screen image viewer). Change here to alter the fetch/build pipeline or which passes run. |
| `htmlclean.lua` | All HTML transformations: strip clutter (navboxes, hatnotes, timeline bars), unwrap article links, drop infobox media cells (or, in lazy mode, keep image cells for the lazy pipeline and drop only video/audio/mapframe), center infobox cells, border infobox/wikitable tables, insert tap-to-rotate hints above/below data tables (rotation handled by main.lua's link handler), merge quote attributions, rewrite `{{Multiple image}}` flexbox into one tiny table per image (boxes inside a kept infobox are hoisted into the infobox's own rows instead, emitted as one full-width cell per row holding proportional inline-block items whose media re-footprints to fill them -- the browser grid), and convert `{{Infobox settlement/columns}}`'s display:table scaffold into a real nested table (crengine ignores display:table); also collects each image box's caption text, keyed by the image's original URL, for epub.lua's sentinel links. Splitting/crengine rationale lives in the code comments. |
| `qrimage.lua` | Owns the shared image-box walker (figure/div.thumb/li.gallerybox, plus kept infoboxes via `treat_infobox_as_imagebox`) and turns every boxed `<img>` into a lazy placeholder span reserving its footprint (lazy placeholders centered via `display:block; margin:0 auto`); rewrites the thumb URL to a sharper standard-size derivative, with the 1x src kept as lazyfetch's failure fallback; drops non-image media (video/audio) wholesale; also collects each image box's caption text keyed by the original image URL for epub.lua's sentinel links. Image mode's name is historical: no QR remains here. |
| `locmap.lua` | Locator maps (Template:Location map): in lazy mode composites each `div.locmap` into ONE PNG — base map thumb downloaded and decoded (`ffi/png`/`ffi/jpeg`) with red marker dots drawn at the template's percentages — and keeps the caption; failures fall back to a plain lazy placeholder of the bare base map. With images disabled htmlclean drops locmaps. |
| `latex.lua` | Math formulas: every formula (block and inline) becomes a marker span for its Wikipedia SVG (deduped by SVG hash, no caps, no fallback); lazyfetch downloads them in the background batch (formulas first). |
| `cladogram.lua` | Clade tables → ASCII tree `<pre>` diagrams. |
| `wikiutil.lua` | Shared helpers: minimal HTTP JSON GET, Wikipedia URL parsing/encoding, HTML notice-tag constants, balanced-tag matching (`findMatchingClose`). |
| `wikireader-cache.lua` | EPUB cache (10 entries / 24 h), stale-file removal, sidecar-aware delete, cache dir handling. |
| `wikireader-history.lua` | Last-10-articles reading history (title/lang references persisted in `G_reader_settings`, no files). |
| `wikireader-bookmarks.lua` | User-bookmarked articles (max 50, newest first), stored as title/lang references in `G_reader_settings` (`wikireader_bookmarks`); never evicts automatically, only via explicit remove/clear. |
| `lazyfetch.lua` | Background completion of lazily-built EPUBs: downloads the whole pending set (formula SVGs first, then photographs) in one batch, triggered by article opens and page turns (`main.lua`'s `onPageUpdate`, coalesced per EPUB so overlapping checks can't stack). Rewrites the zip in place (`.tmp` + rename), keeps the pending entry until nothing remains, removes failed downloads (their `<img>` + manifest item) so no blank squares remain, and seamlessly reloads the open document after each batch. |
| `categories.lua` | Featured-articles category tree built from the API's flat section list; module-level lookup used by the link handler. |
| `mainpage.lua` | Scrapes today's English Wikipedia main page for its "In the news" / "Did you know" / "On this day" boxes (by their stable `mp-*` ids), cleans them, routes their thumbnails through the lazy pipeline when "Show images" is on (`epub.buildMainPageEpub` stitches them in; `lazyfetch` completes the lazy ones), and absolutizes the article links. English-only: other wikis have different main-page titles and id-less markup. |
| `_meta.lua` | Plugin name/version metadata shown in the About dialog. |

## Data flow (one pass each, order matters)

1. `main.lua` resolves title/lang → `epub.buildEpub`.
2. `epub.lua` checks cache → fetches Parsoid HTML from the MediaWiki API.
3. HTML cleaning passes run in sequence (`htmlclean`, `latex`, `cladogram`,
   locmap composites + lazy-image placeholders via `qrimage`); `latex`
   turns every formula into a pending SVG marker (no downloads), `locmap`
   fetches+composites locator maps (capped, lazy fallback on failure; lazy
   mode only).
4. `Wikipedia.createEpub` builds the EPUB; patched `Archiver` hooks inject
   locator-map composites, the formula-SVG `<img>`s (zip entries
   left for lazyfetch), stylesheet, metadata, and the pending-URL list.
5. Result cached as `<lang> - <Title>.epub`; opened via ReaderUI.
6. `lazyfetch` then downloads the whole pending set in the background
   (formula SVGs first, then photographs; the photos list is empty when
   "Show images" is off) and re-triggers on every page
   turn (zip swap + seamless reload per batch).

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
- Validate edits with `luac -p <file>`; also run the feature's script in the
  gitignored local `tests/` folder (`lua tests/test_<name>.lua`) and extend
  it when touching its area. Tests run under system lua; KOReader modules
  are stubbed via `package.preload`, whose entries must be loader functions
  returning the module (plain tables don't work).
- Lua patterns have no alternation (`|` is a literal) — probe shapes with
  sequential finds, as the infobox caption pairing does.
- Find the local koreader codebase using `find / -name "*wikipedia.lua*" 2>/dev/null`
  in case you need to consult koreader scripts.