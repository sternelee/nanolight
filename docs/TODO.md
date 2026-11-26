# Meaning search: progress and what is left

A living list for the vector-search work on branch `embedding`. Each item
says where it stands, so a break in the work does not cost the thread.

## Done

- [x] **Vector index** (`src/vector_index.zig`): one file, no database.
  768-dim float16, L2-normalized, dot product as cosine. Header checked,
  truncated and foreign files refused, bounded search.
- [x] **Model manifest** (`src/embed_model.zig`): EmbeddingGemma 2 Q8_0 at
  a pinned Hugging Face revision, with size and SHA-256. Query/document
  prompts from the model card.
- [x] **Model download** (`src/model_download.zig`): resumable HTTP range,
  streamed to `<name>.partial`, named only after size and SHA-256 match.
  Text part (310 MB) is enough to search; media encoders are optional.
- [x] **Runtime** (`src/embed_runtime.zig`): llama.cpp's pinned
  `llama-server` release as a child process, `/v1/embeddings` over HTTP,
  health-checked before use. Nanolight stays a ~2 MB binary; no C++ linked.
- [x] **Meaning search, live** (`src/semantic_live.zig`): switch, download
  state, query vector, index read. Off-thread, epoch-guarded answers.
- [x] **Settings UI**: "Search by Meaning" row and page, with model state,
  download progress, and a Build Index button.
- [x] **Text extraction** (`src/text_extract.zig`): plain text, Markdown,
  code, HTML (tags/scripts/styles stripped), overlapping word-boundary
  chunks.
- [x] **PDF extraction** (`src/pdf_extract.zig`): PDFKit on the Mac, page by
  page, up to 50 pages. Locked and image-only PDFs skipped. Non-Mac builds
  degrade to unavailable without linking objc.
- [x] **Index builder** (`src/index_builder.zig`): walks the chosen folders,
  extracts text, embeds in batches, writes the index atomically. Runs on a
  background thread with progress.
- [x] **Results**: meaning hits appear under their own "Found by Meaning"
  head, gated at cosine 0.62 (measured gap: related ~0.75-0.85, unrelated
  ~0.45-0.55).

## Review findings (2026-11-25) — must fix before merge

Three independent reviews of the 8 new modules. These are real defects with
code evidence, not style notes. Ordered by severity.

### Critical

- [x] **FIXED — Resume was broken and self-corrupting** (`model_download.zig`).
  The old code truncated `.partial` and wrote at offset 0 while HF's CDN
  answers `Range` with **206** (verified: `content-range: bytes 100-…`), so
  the tail overwrote the head and the download never recovered. Now uses
  `client.request()` + `receiveHead()` to read the status *before* writing:
  a pure `placement()` maps 206 → append at `have`, 200 → restart at 0,
  errors → refuse (no write). Also sets `accept_encoding = .omit` so a
  compressed range cannot poison the file. Two tests cover the decision,
  including a reverse check that writing at 0 on a 206 fails them.
- [x] **FIXED — `flush` leaked every batch's framed strings**
  (`index_builder.zig`). `defer for (batch[0..count.*])` evaluated at scope
  exit, after `count.* = 0`, freeing nothing (~26 KB per batch). Now
  captures `const to_free = count.*` before the reset. Zig's defer timing
  was confirmed with a standalone test.

### High — all fixed

- [x] **Index save is now atomic** (`vector_index.zig`). Writes `<path>.tmp`
  then renames; a failed write leaves the previous index intact and removes
  the temp. Test checks no `.tmp` is left and a second save replaces cleanly.
- [x] **Non-2xx bodies never reach `.partial`** (`model_download.zig`). The
  status is read with `receiveHead` before any write; `.refuse` returns
  without touching the file. Covered by the `placement()` error test.
- [x] **`Hit.path` no longer dangles** (`view.zig`). `meaningAnswered`
  copies each path into `Nanolight.meaning_paths` before keeping the hit, so
  an index rebuild on another thread cannot invalidate a visible row.
- [x] **Meaning-page Return works both ways** (`settings_view.zig`). The
  action moved into `inPanel`'s `.meaning` branch, so a Return delivered as
  `insert_newline` works too. Test drives both paths and fails on the old code.
- [x] **`stripHtml` no longer swallows documents** (`text_extract.zig`). An
  omitted `</head>` ends at `<body>`; a bare `<` in prose is kept as text;
  an unterminated construct no longer drops the rest. Two tests cover it.
- [x] **`chunks` covers the whole window** (`text_extract.zig`).
  `max_chunks` raised from 12 to 26 so 32K of text is indexed to its end;
  each piece still fits the embed framing buffer. Test checks the last piece
  reaches the window's end and fails with the old value.

### Medium

- [x] **Data races on `Live.meaning*` fixed for the query and download
  workers** (`semantic_live.zig`). `AskJob.run` and `FetchJob.run` now only
  use the worker's own buffers and call `App.after(0, ...)`; every `Live`
  write happens in `finish` on the main thread. `index_builder`'s worker
  still writes `meaning_indexing` directly — see the lifecycle item below.
- [x] **A query typed while busy is now embedded** (`semantic_live.zig`).
  `ask` bumps the epoch and returns when a worker is out; that worker's
  `finish` sees the new epoch and calls `dispatch` for the words now in the
  field. `shouldRedispatch()` is a pure helper with a test.
- [x] **Port ownership is now checked** (`embed_runtime.zig`). A /health
  200 is not enough: `ensure` reads `/v1/models` and only accepts a server
  whose model path is our GGUF (`isOurModel`, with a test). A different
  service on the port is refused rather than silently used. A mutex keeps
  the query and index-builder workers from starting/stopping at once.
- [x] **One server, kept and stopped when idle** (`semantic_live.zig`,
  `index_builder.zig`). The server lives in `Live.meaning.server`; queries
  and the index build share it. A query invalidates a queued idle stop by
  bumping a token, and a finished query schedules a stop after 30 s to
  return the model's ~0.25 GB. Measured: first ensure 1876 ms, second
  ensure 0 ms, after stop 1463 ms -- the old code paid ~1.5 s per query.
- [ ] **Detached threads outlive `Live`** (`semantic_live.zig:107,166`,
  `index_builder.zig:86`). `Live` is a stack value in `main`; on quit the
  detached workers still dereference it. No cancellation or join.
- [x] **`search` no longer underflows on an empty `out`**
  (`vector_index.zig`). Returns zero before the `out[n - 1]` comparison;
  the test aborts with signal ABRT on the old code.
- [x] **`parse` validates `count` before allocating** (`vector_index.zig`).
  A record needs at least 19 bytes; a claimed count larger than the bytes
  allow is refused as `Truncated` before any allocation. Test uses a
  36-byte file claiming `0xFFFFFFFF` records.
- [ ] **Fingerprint ignores the prompts it claims to cover**
  (`embed_model.zig:58-72`). Changing prompt wording without bumping `:v1`
  silently invalidates recall. The `Index.model` field is written but never
  compared on load.
- [ ] **`problem` out-param has no length** (`model_download.zig:104-155`,
  `semantic_live.zig:146`). Callers copy all 96 bytes, so the message
  carries ~70 trailing NULs and `len > 0` is always true.
- [ ] **Request bodies can overflow** (`index_builder.zig:200`,
  `semantic_live.zig:214`). JSON escaping doubles quotes/backslashes and
  sextuples control bytes; a batch of 16 quote-heavy chunks exceeds
  `body_buf` and aborts the build.
- [ ] **Long basenames silently drop a chunk** (`index_builder.zig:156`).
  `documentText` returns null past ~240 bytes of title and the piece is
  skipped.
- [ ] **No download timeout or cancel** (`model_download.zig:160-214`).
  A stalled server blocks the worker forever; `fetching` stays true and
  retries are refused.

### Low

- `tidy` turns CRLF into two newlines (`text_extract.zig:90-97`).
- Footer says "Turn On" when already on, and Return then turns it off
  (`settings_view.zig:386`).
- `rebuild` keeps the previous query's hits until the new vector lands
  (`view.zig:354-369`); `meaning_query` is written but never read.
- Progress bar is a hardcoded 560 px (`settings_view.zig:360`).
- `missing()` treats an unprintable path as "file present"
  (`model_download.zig:52`).
- `normalize` passes NaN through (`vector_index.zig:242-248`).

### Test gaps

- `download` / `fetchOne` / `FileSink` have **no tests** — the most
  dangerous 200 lines in the change. C1 and the 404 poisoning were only
  found by reading.
- The fingerprint test compares the constant to itself
  (`embed_model.zig:107-113`); it cannot fail.
- No test for empty `out`, a lying `count`, `save` failing mid-write,
  `stripHtml` with an omitted `</head>`, or `chunks` coverage past 15K.

## Done since the review

- [x] **Office documents** (`src/office_extract.zig`): docx, xlsx and pptx
  text extraction. Zig 0.17 ships `std.zip`, so no archive dependency; a
  small pull XML tokenizer handles names, attributes and text. docx reads
  `word/document.xml` paragraphs, xlsx resolves shared strings in sheet
  cells (`t="s"`), pptx reads each slide's `a:t`. Verified against real
  generated files: all three extract the expected words. A search of the
  Zig library space found no dedicated Zig Office parser; `zig-utils/zig-xml`
  works but declares a dev-only Zig version, so it was not taken on.

## Not done

- [ ] **Images and media**: needs the 555 MB mmproj encoder, image resizing,
  and audio windowing. The largest remaining piece of the "search
  everything" goal.
- [ ] **Scanned PDFs / OCR**: pages with no text layer are skipped today.
  Rendering plus OCR (Vision on the Mac) would cover them.
- [ ] **Incremental indexing**: a build rewrites the whole index. Changed
  files are re-read on the next full build; there is no watcher or per-file
  update yet.
- [ ] **Commit**: all of this is uncommitted on `embedding` (8 new modules
  plus edits to main/view/results/settings/build).
- [ ] **Push**: `origin/embedding` does not exist yet.

## Verification so far

- `zig build test-bin`: 138 passed, 1 skipped, 0 failed.
- `zig build`, `zig build film`, Windows and Linux cross-compiles: all exit 0.
- End-to-end probes against a real model: download + SHA-256, server start,
  embed, index, query. A dog query ranked a dog file 0.776 and a budget file
  0.499, with the 0.62 gate keeping only the former.
- Resume verified for real: a 100-byte `.partial` of a 410-byte file, then
  `fetchOne` completed it via 206 and the SHA-256 matched — the exact path
  that was broken before the fix.
- Office extraction verified against generated docx/xlsx/pptx files.
