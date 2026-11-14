#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| dox_pdf_lib::fuzz::svg(data));
