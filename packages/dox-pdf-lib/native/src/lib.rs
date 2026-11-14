//! Native core of dox_pdf_lib. One module per feature area, so a new area
//! is one new line here. See CONTRIBUTING.md, "Native layout".

mod attachment;
mod conformance;
mod custom_font;
mod document;
mod draw;
mod embed;
mod ffi_util;
mod font;
mod form;
mod image;
mod metadata;
mod page;
mod segment;

// the entry points of the fuzz targets in `fuzz/`
#[cfg(fuzzing)]
pub mod fuzz;
