# Contributing to dox-pdf-lib

Thank you for your help.

This repo is a Dart pub workspace. The packages are in `packages/`:
`dox_pdf_lib` in `packages/dox-pdf-lib` and `dox_pdf_me` in
`packages/dox-pdf-me`. Run `dart pub get` once at the root.

## Bugs and feature requests

Use GitHub issues: https://github.com/dartondox/dox-pdf-lib/issues

For security problems, see [SECURITY.md](SECURITY.md). Do not open a public issue.

## Pull requests

Send changes as pull requests against `main`. Before you ask for review:

- CI is green.
- In `packages/dox-pdf-lib/native/`: `cargo fmt`, `cargo clippy --release --all-targets -- -D warnings` and `cargo test` pass.
- `dart format` is clean (run it at the root).
- `dart analyze --fatal-infos` has no warnings (run it at the root).
- Add a changelog entry under `## Unreleased` in the `CHANGELOG.md` of the package.
- Do not change versions in the PR.
- After a change of `packages/dox-pdf-lib/native/Cargo.toml` or `Cargo.lock`, run `dart run tool/third_party_notices.dart` in `packages/dox-pdf-lib` (CI checks `THIRD_PARTY_NOTICES`).

## Releases

Each package has its own version and its own tags: `<package>-v<version>`,
eg. `dox_pdf_lib-v0.0.2` or `dox_pdf_me-v0.0.1`. A tag on `main` runs
`.github/workflows/release.yaml`. It runs the tests first, and publishes
the package to pub.dev only when they pass.

## dox_pdf_me

The paths are in `packages/dox-pdf-me`.

- Goal: the same page look as the pdfme generator for the same template and
  inputs. Read the pdfme source of a feature first and match it.
  `README.md` lists the known differences. Keep that list up to date.
- One class per schema type (`SchemaPlugin`). Shared code: `lib/src/layout.dart`
  (boxes and rotation), `lib/src/color.dart`, `lib/src/fonts/`.
- Tests: `dart test`. The line break tables in `lib/src/text/` come from
  pdfme (Unicode 18). Do not edit them by hand.
- Crosscheck with pdfme: run `npm ci` in `tool/crosscheck` (Node.js), and
  install pdftoppm (poppler-utils). `test/crosscheck_test.dart` renders the
  cases of `tool/crosscheck/cases.mjs` with pdfme and with dox_pdf_me, and
  compares each schema box on its own: the ink box (place and size) and the
  pixels, with tight limits per type, and the bars of linear barcodes. It
  writes all numbers to `.dart_tool/crosscheck/report.txt`. With `zbarimg`
  (zbar-tools) it also decodes the 2D codes. Without node_modules the test
  is skipped. CI always runs it. Add a case there for every new feature.
- Barcodes: the 2D codes and Code 128 are ports of the BWIPP encoders
  (`lib/src/barcodes/`). `test/fixtures/barcodes/*_bwip.json` hold the
  modules bwip-js 4.11.4 makes (with `bwipjs.raw`); `test/barcode_test.dart`
  compares every module. `lib/src/barcodes/gs1_syntax.dart` is made by
  `node tool/crosscheck/make_gs1_syntax.mjs lib/src/barcodes/gs1_syntax.dart`,
  and `test/fixtures/barcodes/barcode_errors.json` (the errors pdfme throws)
  by `node tool/crosscheck/make_barcode_errors.mjs <file>`.
- Thai, Lao, Khmer and Myanmar word breaks: `test/fixtures/sa_word_breaks.json`
  holds pdfme's breaks for the sentences of `tool/crosscheck/sa_text.mjs`.
  Make it again with `node tool/crosscheck/word_breaks.mjs
  test/fixtures/sa_word_breaks.json` (Node.js 24, after `npm ci`). The ICU
  of Node.js decides the words, so do not use another Node.js version.

## dox_pdf_lib

The rest of this file is about `dox_pdf_lib`. The paths are in
`packages/dox-pdf-lib`.

### Goal

The same API, names, defaults and behavior as pdf-lib. When you add a
feature, read the pdf-lib source of it first and match it.

### Native layout

The rules below keep the code fast, and let features be built in parallel
without merge conflicts.

**One file per feature area.**

- Rust: `native/src/<area>.rs`. Now: `ffi_util.rs`, `document.rs`, `page.rs`, `metadata.rs`. Later eg. `draw.rs`, `font.rs` (with `custom_font.rs`), `image.rs`, `form.rs`, `attachment.rs`, `embed.rs`, `segment.rs` (word breaks, no document).
- Dart bindings: `lib/src/ffi/<area>_bindings.dart`.
- Dart API: `lib/src/api/<area>.dart`. Code that needs the private parts of `PDFDocument` or `PDFPage` (eg. the handle) is a `part of 'document.dart'`, often an `extension` on `PDFDocument` or `PDFPage` (see `metadata.dart`).
- `native/src/lib.rs`, the `part` list in `lib/src/api/document.dart` and `lib/dox_pdf_lib.dart` are short lists. A new area adds one line to each.

**The document lives in Rust.**

- Dart holds an opaque handle (`Pointer<Void>`, an `Arc<Mutex<Doc>>` in Rust) with a `NativeFinalizer` (`dox_pdf_doc_free`), and an explicit `dispose()`.
- New state of a feature (eg. fonts to embed at save) goes into `Doc` in `ffi_util.rs`. Keep `Doc` `Clone`: a later in-memory copy of a loaded document (load a template once, make many outputs) is a clone under the lock, with no parse.
- A `PDFPage` is the document and the page object ref (`number << 16 | generation`).

**One FFI call per API call.**

- No chatty calls per object. Do the whole API call in Rust.
- Bytes cross FFI once on load and once on save.
- Small inputs and outputs use typed data (`Uint8List.address`, `Int64List.address`, `Float64List.address`) in leaf calls. No malloc in Dart.
- Bytes from Rust (a saved file, a string) are a `Bytes` record. Dart wraps them with `takeBytes` as a `Uint8List` whose finalizer frees them. There is no copy and no free call.

**Errors.**

- Every export returns an `i32` status: `OK` (0), `PENDING` (1) or an error code (`ffi_util.rs`, the same numbers in `ffi_util.dart`).
- Every export runs in `ffi_util::call`, which catches panics (`catch_unwind`). A panic never crosses FFI. The release profile uses `panic = "unwind"` for this. Do not change it to `abort`.
- On an error, the message is in a thread-local slot. `check()` in Dart reads it with `dox_pdf_last_error` right away, in the same synchronous code (so on the same thread).
- Dart throws typed errors with pdf-lib names (`EncryptedPDFError`, `RemovePageFromEmptyDocumentError`, ...). Add a new status and a new class in `lib/src/api/errors.dart` when you need one.

**Work that can be slow.**

- Load and save of a big file (1 MiB or more, `ASYNC_THRESHOLD`) run on a Rust thread. The export returns `PENDING`, and the thread reports with a callback (`NativeCallable.listener`, see `Pending` in `ffi_util.dart`). Small files run inline, because a thread costs more than the work.
- A Rust thread is cheaper than `Isolate.run` (tens of microseconds, not about a millisecond), and the bytes do not have to go to another isolate.
- Calls on one document wait for each other (a mutex). Save copies the document under the lock (`Doc` is `Clone`) and writes the copy without it, so other calls do not wait for a big save. Do the same for other slow work that only reads the document.

**Untrusted input.**

- Load must never crash the process on a broken PDF. It returns an error.
- Walks over the object graph have a limit (`MAX_DEPTH`) and skip loops. Use explicit stacks, not deep recursion.

### Tests

Every new feature and every bug fix must add tests.

- Rust: `cargo test` in `native/`.
- Dart: `dart test`.
- Crosscheck with pdf-lib: run `npm ci` in `tool/crosscheck` (needs Node.js). Then `dart test test/crosscheck_test.dart` compares what dox_pdf_lib and pdf-lib read from the same files. Without `node_modules` the test is skipped. CI always runs it.
- Drawing crosscheck: `test/draw_crosscheck_test.dart` draws the same scene as `tool/crosscheck/draw.mjs` and compares the pages rendered by `pdftoppm` (poppler-utils), and the font metrics. Keep the two scenes the same.
- Font crosscheck: `test/font_crosscheck_test.dart` embeds the same custom fonts as `tool/crosscheck/fonts.mjs` (pdf-lib + @pdf-lib/fontkit), and compares the metrics and the encoded text exactly, the rendered pages, and the text of `pdftotext`. The test fonts are downloaded once into `.dart_tool/test_fonts` (see `test/render_support.dart`). Small fonts for unit tests are in `test/fixtures/fonts`.
- Language matrix: `test/language_test.dart` draws real sentences in 11 languages (Noto fonts, full and subset) and checks copy and paste (`pdftotext`), wrapping, the render (against pdf-lib, or not blank and no `.notdef`), and the widths (exactly pdf-lib + fontkit, or for complex scripts `hb-shape` from HarfBuzz, `libharfbuzz-bin`). `tool/crosscheck/languages.mjs` makes the pdf-lib side.
- `native/src/fonts.bin` holds the standard font metrics of `@pdf-lib/standard-fonts`. `node tool/crosscheck/gen_fonts.mjs` makes it again.
