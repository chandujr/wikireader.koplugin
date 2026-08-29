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
| `qrimage.lua` | Replaces media with QR codes (renders QR via KOReader's `ffi/qrencode`, writes minimal PNGs, rewrites media boxes to placeholder `<img>`s). |
| `latex.lua` | LaTeX formula → Unicode transcription (replaces `MathML`/images). |
| `cladogram.lua` | Clade tables → Unicode box-drawing `<pre>` diagrams. |
| `wikiutil.lua` | Shared helpers: minimal HTTP JSON GET, Wikipedia URL parsing/encoding, HTML notice-tag constants, balanced-tag matching (`findMatchingClose`). |
| `wikireader-cache.lua` | EPUB cache (10 entries / 24 h), stale-file removal, sidecar-aware delete, cache dir handling. |
| `categories.lua` | Featured-articles category tree built from the API's flat section list; module-level lookup used by the link handler. |
| `_meta.lua` | Plugin name/version metadata shown in the About dialog. |

## Data flow (one pass each, order matters)

1. `main.lua` resolves title/lang → `epub.buildEpub`.
2. `epub.lua` checks cache → fetches Parsoid HTML from the MediaWiki API.
3. HTML cleaning passes run in sequence (`htmlclean`, `latex`, `cladogram`,
   QR placeholders via `qrimage`).
4. `Wikipedia.createEpub` builds the EPUB; patched `Archiver` hooks inject
   QR PNGs, stylesheet, metadata.
5. Result cached as `<lang> - <Title>.epub`; opened via ReaderUI.

## Commenting strategy (important)

- Add comment **only if necessary**.
- Comments explain **why**, never **what**. No comment should restate the
  function name, narrate the next line, or label a section the code already
  shows.
- Keep (and write) comments that capture non-obvious external knowledge:
  KOReader internals (plugin lifecycle, `.sdr` sidecars, monkey-patched
  hooks), crengine limitations (no flexbox, table quirks), MediaWiki/Parsoid
  HTML quirks, and traps (Lua `gsub` `%`-escaping, patterns can't do
  balanced matching).
- When adding code, add a `why`-comment only where the code alone can't be
  understood. When editing, condense verbose comments rather than growing
  them — but never delete rationale-bearing content.

## Notes for LLMs

- Lua 5.1-compatible; no external dependencies beyond KOReader's runtime.
- `nav_history`/`nav_current` in `main.lua` are module-level on purpose
  (KOReader rebuilds plugin instances per UI) — do not move them to `self`.
- Validate edits with `luac -p <file>`; no test suite exists.
- KOReader local codebase (for `ui/wikipedia.lua`, `Archiver`, widgets) is
  probably at `/usr/lib/koreader` — consult it if needed.
