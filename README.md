# Highlights for KOReader

A KOReader plugin to browse, search, tag, rediscover and export the highlights from all your books. It is designed for e-ink first, with the Tango 2 (824 × 1648) as the reference screen.

## Install

1. Copy the `hlmanager.koplugin` folder into KOReader's `plugins` folder. On Android that is `/storage/emulated/0/koreader/plugins/`.
2. Restart KOReader.
3. Open **Tools ▸ Highlights**. You can also assign **Highlights: library** or **Highlights: Vagary** to a gesture or key under *Taps and gestures ▸ Gesture manager*.

Books are found through your reading history, the same source KOReader's own "Export all notes" uses. The first visit reads every book's highlights. After that, only books changed since the last visit are re-read, and the book open in the reader is read from memory.

## Screens

| Tab | What it does |
|---|---|
| **Library** | Search, plus filter chips for Books, Authors, Tags and Time. Long-press an active chip to clear only that filter. Sort by newest, oldest, or **by book, in reading order**. Results come a page at a time. Long-press a row to start selecting, then Tag, Export or Delete the selection. The ☰ menu has **Export…**, Select and Rescan. |
| **Vagary** | One random highlight, shown large. Nothing repeats until every highlight in the current draw has been shown; this survives restarts and starts over when the draw's filter changes. Long quotes shrink to fit, then offer "Continue reading". To draw another, tap the quote, tap Another, swipe left or press page-forward. Page-back goes to the previous one. |
| **Tags** | Create tags and sort by most used, A–Z or recent. Tap a tag, or *Untagged*, to see its highlights. Long-press a tag or use its menu button to rename, merge or delete it. |

<img width="1318" height="515" alt="Screenshot 2026-10-09 at 00 17 37" src="https://github.com/user-attachments/assets/d39ab2e8-dc7a-4d00-95ba-48020d96e1d8" />

The detail, filter, tag picker and export screens open on top of the tab you are on. Close them with ✕, ‹, Back or a swipe down.

**Export** is in the Library menu and in the selection bar. It writes Markdown, Obsidian (one note per book), plain text, CSV (UTF-8 with a BOM, so Excel shows Chinese correctly) or JSON. Files go to `<KOReader folder>/data/HLexport/` by default; on Android that is `/storage/emulated/0/koreader/data/HLexport/`. If a file with today's name already exists, you choose *Keep both* (adds `-2`) or *Replace*.

## E-ink and device decisions

- **Sizes** are density-independent (`Screen:scaleBySize`), so the layout carries over to any panel. Tap targets are at least 44 dp, about 7 mm. Removing a tag is a long-press with a confirmation, not a small ✕.
- **Rotation is supported.** Lists use fixed-height rows, so rows per page follow the free height. In landscape, lists switch to two columns, the pager and tabs share one row, and Detail and Export split into two columns.
- **Pages, never scrolling.** Swipe left/right or use the page-turn keys. Tap "Page x of y" to jump to a page.
- **Refreshes:** a full flashing refresh when a screen opens or closes, cheaper partial refreshes inside a screen.
- **Selected means solid black.** Only white, black and two greys are used, so KOReader's night mode simply inverts everything.
- **Fonts:** Noto Serif for quotes and the KOReader UI font for everything else. Both are bundled with KOReader and fall back to Noto Sans CJK for Chinese. Quotes can use the UI font instead (*Highlights ▸ Quote font*). No arrow glyphs (▾ ⇅ ⇄) that the bundled fonts might not contain.
- **Page numbers in reflowable books change with font size.** A location is shown as "Ch. · 20% · p. 214 when highlighted", and *Open in book* jumps to the stored position, not to the page number. Publisher page labels are shown as they are.
- **Coming back after "Open in book":** the plugin remembers the last tab, filter, sort, page and Vagary quote, so reopening it returns you where you were.

## Data

| File (in KOReader's `settings` folder) | Holds |
|---|---|
| `hlmanager.sqlite3` | Index of highlights, tags and Vagary history |
| `hlmanager.lua` | Filters, sort, page, export options |

KOReader's book metadata (`.sdr/metadata.*.lua`) stays the source of truth for highlight text and notes. Tags have no place there, so they are stored in the plugin's database. Each tag is linked to a highlight by the book's checksum plus the highlight's creation time, so tags survive re-indexing and moving or renaming the book.

Editing a note or deleting a highlight changes the book itself:

- **Book open in the reader:** the change goes through KOReader's own annotation code.
- **Book not open:** the change is written to the book's metadata file, and the book is flagged so the reader refreshes page numbers and statistics the next time it is opened.

## Known limitations

- The plugin has not yet run inside KOReader on a device. It was tested on a desktop with a harness (see below) that copies KOReader's layout and event rules.
- Books whose metadata predates KOReader's 2024 annotation format show up after you open them once in a current KOReader.
- Deleting a highlight from a PDF that is not open removes KOReader's record of it, but not an annotation that KOReader wrote into the PDF file itself.
- If a book's file has been deleted, its highlights stay browsable and exportable, but *Open in book* is disabled.

## Development

```bash
dev/run_tests.sh
```

- **`test_data.lua`** checks the SQLite store, indexing, filters, sorting, tags, the Vagary no-repeat logic and every export format. It uses the real `lua-ljsqlite3` and SQLite.
- **`test_ui.lua`** drives the real plugin code through stand-ins for KOReader's widgets (`uistubs.lua`). It opens every screen, taps by text, swipes and confirms dialogs, at six screen sizes in portrait and landscape. It also checks that nothing is drawn off-screen or overflows its box.
- **Previews:** with `KOREADER_SRC` pointing at a KOReader checkout, `--previews` also renders approximate previews of each screen to `dev/previews/index.html`.

The plugin's modules live under `hlm/`, so they cannot collide with other plugins' module names. The main modules:

| Module | Role |
|---|---|
| `kit` | UI building blocks |
| `store` | SQLite |
| `indexer` | Reads book metadata |
| `model` | Filtering and sorting |
| `export` | File formats |
| `app` | Navigation and actions |
| `screens/*` | The screens |
