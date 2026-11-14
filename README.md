# dox-pdf-lib

PDF packages for Dart. Each package is in `packages/` and has its own
version and its own releases.

| Package | What it is |
| --- | --- |
| [dox_pdf_lib](packages/dox-pdf-lib) ([pub.dev](https://pub.dev/packages/dox_pdf_lib)) | Create and edit PDF documents, with the API of the pdf-lib JavaScript library. A native Rust core does the work through dart:ffi. |
| [dox_pdf_me](packages/dox-pdf-me) ([pub.dev](https://pub.dev/packages/dox_pdf_me)) | Make PDF documents on top of dox_pdf_lib. Work in progress. |

Run `dart pub get` once at the root. It links all packages (a Dart pub
workspace).

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

MIT. See [LICENSE](LICENSE).
