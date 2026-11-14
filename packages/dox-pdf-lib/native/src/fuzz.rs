//! Entry points of the fuzz targets in `fuzz/` (built with `cfg(fuzzing)`
//! only). Each one runs untrusted bytes through the same code a Dart call
//! runs. Errors are fine; a crash, a hang or a huge allocation is a bug.
//! A file we write must load again, so that is checked too.

use crate::conformance::{self, Standard};
use crate::custom_font::{self, CustomFont};
use crate::document::{self, LOAD_IGNORE_ENCRYPTION, SAVE_ADD_DEFAULT_PAGE, SAVE_UPDATE_FIELD_APPEARANCES};
use crate::embed::{self, Request};
use crate::{attachment, draw, form, image, metadata, page};

const NOW: &[u8] = b"D:20260101000000Z";

/// A PDF file: read everything, fill and flatten the form, embed its pages,
/// save, and load the result again.
pub fn load(data: &[u8]) {
    let Ok(mut doc) = document::load(data, LOAD_IGNORE_ENCRYPTION, NOW) else {
        return;
    };
    let Ok(pages) = document::page_entries(&doc.pdf) else {
        return;
    };
    for p in &pages {
        for kind in 0..5 {
            let _ = page::get_box(&doc.pdf, p.id, kind);
        }
        let _ = page::get_rotation(&doc.pdf, p.id);
    }
    for key in [&b"Title"[..], b"Author", b"CreationDate", b"Keywords"] {
        let _ = metadata::get(&doc.pdf, key);
    }
    let _ = attachment::list(&doc.pdf);
    // checkConformance and the XMP of a loaded file
    let _ = conformance::get_xmp(&doc.pdf);
    let _ = conformance::make_xmp(&doc.pdf, Some(Standard::A1b));
    for s in [Standard::X1a, Standard::A2u] {
        let _ = conformance::check(&doc, s);
    }
    form::fuzz_fill(&mut doc);
    let reqs: Vec<Request> = pages
        .iter()
        .take(2)
        .map(|p| Request {
            page: p.id,
            bbox: None,
            matrix: None,
        })
        .collect();
    let _ = embed::embed_own(&mut doc, &reqs);
    // the same two steps as `dox_pdf_save`
    let mut flags = SAVE_ADD_DEFAULT_PAGE | SAVE_UPDATE_FIELD_APPEARANCES;
    let Ok(pdf) = document::prepare_save(&mut doc, &mut flags) else {
        return;
    };
    let Ok(out) = document::write(pdf, flags) else {
        return;
    };
    // what we write must load again
    let again = document::load(&out, LOAD_IGNORE_ENCRYPTION, NOW);
    assert!(
        again.is_ok(),
        "our own output does not load: {:?}",
        again.err().map(|e| e.message)
    );
}

/// A font file: lay out text in many scripts, measure, wrap, and write the
/// font (full and subset) into a PDF.
pub fn font(data: &[u8]) {
    let Ok(file) = custom_font::load(data) else {
        return;
    };
    let texts = [
        "Hello, world! ffi fl 123",
        "Grüße ẞ ÄÖÜ",
        "Tiếng Việt",
        "日本語のテキスト、カタカナ",
        "한국어 텍스트",
        "ภาษาไทย น้ำ ค่ำ",
        "မြန်မာဘာသာ",
        "ភាសាខ្មែរ",
        "مرحبا 123 world",
        "हिन्दी पाठ",
        "😀 \u{200d}\u{0301}",
        "",
    ];
    for subset in [true, false] {
        let f = CustomFont::new(file.clone(), subset, "Fuzz".to_string(), Vec::new());
        for t in texts {
            let _ = f.layout(t);
            let _ = f.width_of_text(t, 12.0);
            let _ = f.break_points(t);
            let _ = f.encode(t);
            let _ = f.show_text(t, 12.0, None);
            let _ = f.show_text(t, 12.0, Some(true));
        }
        let mut pdf = lopdf::Document::with_version("1.7");
        let id = pdf.new_object_id();
        let _ = f.write(&mut pdf, id);
    }
}

/// An image: the first byte picks JPEG or PNG.
pub fn image(data: &[u8]) {
    let Some((&pick, data)) = data.split_first() else {
        return;
    };
    let mut pdf = lopdf::Document::with_version("1.7");
    if pick & 1 == 0 {
        let _ = image::embed_jpg(&mut pdf, data);
    } else if image::png_decoded_size(data).is_ok()
        && let Ok(png) = image::decode_png(data)
    {
        image::add_png(&mut pdf, png);
    }
}

/// An SVG path string.
pub fn svg(data: &[u8]) {
    if let Ok(path) = std::str::from_utf8(data) {
        draw::fuzz_svg(path);
    }
}

/// Text for the word breaks: the bytes as UTF-16 code units (also lone
/// surrogates), and as UTF-8 when they are valid. The breaks must go up and
/// stay inside the text.
pub fn segment(data: &[u8]) {
    let units: Vec<u16> = data
        .chunks(2)
        .map(|c| u16::from_le_bytes([c[0], *c.get(1).unwrap_or(&0)]))
        .collect();
    let mut texts = vec![units];
    if let Ok(s) = std::str::from_utf8(data) {
        texts.push(s.encode_utf16().collect());
    }
    for text in texts {
        let b = crate::segment::dictionary_breaks(&text);
        assert!(b.windows(2).all(|w| w[0] < w[1]), "breaks go up: {b:?}");
        assert!(b.iter().all(|&x| x > 0 && x < text.len()), "breaks inside: {b:?}");
    }
}

/// ICC profile bytes and XMP text from the user: the header check, an
/// output intent, a conformance save and the XMP made from Info text.
pub fn conformance(data: &[u8]) {
    let _ = conformance::read_icc(data);
    let mut doc = document::create(true, NOW);
    let text = String::from_utf8_lossy(data);
    let _ = metadata::set(&mut doc.pdf, b"Title", &text, metadata::MODE_TEXT);
    let _ = metadata::set(&mut doc.pdf, b"CreationDate", &text, metadata::MODE_LITERAL);
    let xmp = conformance::make_xmp(&doc.pdf, Some(Standard::A2u));
    assert!(xmp.ends_with("<?xpacket end=\"w\"?>"));
    let _ = conformance::xmp_date(&text);
    let intent = conformance::Intent {
        subtype: b"",
        identifier: "Fuzz",
        condition: "",
        registry: "",
        info: "",
    };
    if conformance::set(&mut doc, Standard::A2b, data, &intent).is_ok() {
        let _ = conformance::set_xmp(&mut doc.pdf, &text);
        let Ok(out) = document::save(&mut doc, SAVE_ADD_DEFAULT_PAGE) else {
            return;
        };
        let again = document::load(&out, LOAD_IGNORE_ENCRYPTION, NOW);
        assert!(again.is_ok(), "our own output does not load");
    }
}
