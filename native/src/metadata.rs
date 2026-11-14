//! Document metadata: the `/Info` dict (title, author, dates, ...) and the
//! catalog `/Lang`. Text goes to Dart as UTF-8. Dates stay PDF date text;
//! Dart parses and formats them, like pdf-lib.

use std::ffi::c_void;

use lopdf::{Dictionary, Document, Object, StringFormat};

use crate::document::deref;
use crate::ffi_util::*;

/// The default `/Producer` (always set) and `/Creator` (set when missing),
/// like pdf-lib does with its own name.
pub const PRODUCER: &str = "dox_pdf_lib (https://github.com/dartondox/dox-pdf-lib)";

/// Set modes from Dart.
#[cfg(test)]
pub const MODE_TEXT: i32 = 0;
pub const MODE_LITERAL: i32 = 1;
/// Also set `/ViewerPreferences /DisplayDocTitle true` (setTitle option).
pub const FLAG_SHOW_TITLE: i32 = 4;

/// The `/Info` dict, made when there is none (pdf-lib's `getInfoDict`).
fn info_mut(pdf: &mut Document) -> &mut Dictionary {
    let id = match pdf.trailer.get(b"Info") {
        Ok(Object::Reference(id)) if matches!(pdf.objects.get(id), Some(Object::Dictionary(_))) => Some(*id),
        Ok(Object::Dictionary(_)) => None,
        _ => {
            let id = pdf.add_object(Object::Dictionary(Dictionary::new()));
            pdf.trailer.set("Info", Object::Reference(id));
            Some(id)
        }
    };
    match id {
        Some(id) => match pdf.objects.get_mut(&id) {
            Some(Object::Dictionary(d)) => d,
            _ => unreachable!("checked above"),
        },
        None => match pdf.trailer.get_mut(b"Info") {
            Ok(Object::Dictionary(d)) => d,
            _ => unreachable!("checked above"),
        },
    }
}

fn info(pdf: &Document) -> Option<&Dictionary> {
    match deref(pdf, pdf.trailer.get(b"Info").ok()?)? {
        Object::Dictionary(d) => Some(d),
        _ => None,
    }
}

fn catalog_id(pdf: &Document) -> Result<lopdf::ObjectId> {
    match pdf.trailer.get(b"Root") {
        Ok(Object::Reference(id)) => Ok(*id),
        _ => Err(Error::generic("the document has no catalog")),
    }
}

/// pdf-lib's `PDFHexString.fromText`: UTF-16BE with a BOM, as hex.
pub fn text_object(text: &str) -> Object {
    let mut bytes = vec![0xfe, 0xff];
    for unit in text.encode_utf16() {
        bytes.extend_from_slice(&unit.to_be_bytes());
    }
    Object::String(bytes, StringFormat::Hexadecimal)
}

/// pdf-lib's `decodeText`: UTF-16 with a BOM, else PDFDocEncoding. We also
/// read UTF-8 with a BOM (PDF 2.0).
pub fn decode_text(bytes: &[u8]) -> String {
    let utf16 = |be: bool| {
        let units: Vec<u16> = bytes[2..]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| {
                if be {
                    u16::from_be_bytes([c[0], c[1]])
                } else {
                    u16::from_le_bytes([c[0], c[1]])
                }
            })
            .collect();
        String::from_utf16_lossy(&units)
    };
    match bytes {
        [0xfe, 0xff, ..] => utf16(true),
        [0xff, 0xfe, ..] => utf16(false),
        [0xef, 0xbb, 0xbf, rest @ ..] => String::from_utf8_lossy(rest).into_owned(),
        _ => bytes.iter().map(|&b| pdf_doc_char(b)).collect(),
    }
}

/// PDFDocEncoding to Unicode (PDF spec table D.2, as in pdf-lib).
fn pdf_doc_char(b: u8) -> char {
    const HIGH: [char; 33] = [
        '\u{2022}', '\u{2020}', '\u{2021}', '\u{2026}', '\u{2014}', '\u{2013}', '\u{0192}', '\u{2044}', '\u{2039}',
        '\u{203A}', '\u{2212}', '\u{2030}', '\u{201E}', '\u{201C}', '\u{201D}', '\u{2018}', '\u{2019}', '\u{201A}',
        '\u{2122}', '\u{FB01}', '\u{FB02}', '\u{0141}', '\u{0152}', '\u{0160}', '\u{0178}', '\u{017D}', '\u{0131}',
        '\u{0142}', '\u{0153}', '\u{0161}', '\u{017E}', '\u{FFFD}', '\u{20AC}',
    ];
    const LOW: [char; 8] = [
        '\u{02D8}', '\u{02C7}', '\u{02C6}', '\u{02D9}', '\u{02DD}', '\u{02DB}', '\u{02DA}', '\u{02DC}',
    ];
    match b {
        0x16 => '\u{0017}',
        0x18..=0x1f => LOW[(b - 0x18) as usize],
        0x7f | 0xad => '\u{FFFD}',
        0x80..=0xa0 => HIGH[(b - 0x80) as usize],
        _ => b as char,
    }
}

pub fn get(pdf: &Document, key: &[u8]) -> Result<Option<String>> {
    let value = if key == b"Lang" {
        let catalog = pdf.get_dictionary(catalog_id(pdf)?)?;
        catalog.get(b"Lang").ok().and_then(|v| deref(pdf, v))
    } else {
        info(pdf).and_then(|d| d.get(key).ok()).and_then(|v| deref(pdf, v))
    };
    match value {
        None => Ok(None),
        Some(Object::String(bytes, _)) => Ok(Some(decode_text(bytes))),
        Some(other) => Err(Error::generic(format!(
            "Expected instance of PDFHexString or PDFString, but got instance of {}",
            other.enum_variant()
        ))),
    }
}

pub fn set(pdf: &mut Document, key: &[u8], value: &str, mode: i32) -> Result<()> {
    let object = if mode & MODE_LITERAL != 0 {
        Object::String(value.as_bytes().to_vec(), StringFormat::Literal)
    } else {
        text_object(value)
    };
    if key == b"Lang" {
        let id = catalog_id(pdf)?;
        pdf.get_dictionary_mut(id)?.set("Lang", object);
        return Ok(());
    }
    info_mut(pdf).set(key.to_vec(), object);
    if mode & FLAG_SHOW_TITLE != 0 {
        let id = catalog_id(pdf)?;
        // the prefs dict may be a reference; pdf-lib makes it direct when missing
        let prefs = match pdf.get_dictionary(id)?.get(b"ViewerPreferences") {
            Ok(Object::Reference(r)) => Some(*r),
            _ => None,
        };
        let prefs = match prefs {
            Some(r) => pdf.get_dictionary_mut(r)?,
            None => {
                let catalog = pdf.get_dictionary_mut(id)?;
                if !matches!(catalog.get(b"ViewerPreferences"), Ok(Object::Dictionary(_))) {
                    catalog.set("ViewerPreferences", Object::Dictionary(Dictionary::new()));
                }
                catalog.get_mut(b"ViewerPreferences")?.as_dict_mut()?
            }
        };
        prefs.set("DisplayDocTitle", Object::Boolean(true));
    }
    Ok(())
}

/// pdf-lib's `updateInfoDict`, run by create and load.
pub fn update_info(pdf: &mut Document, now: &[u8]) {
    let now = Object::String(now.to_vec(), StringFormat::Literal);
    let info = info_mut(pdf);
    info.set("Producer", text_object(PRODUCER));
    info.set("ModDate", now.clone());
    if !info.has(b"Creator") {
        info.set("Creator", text_object(PRODUCER));
    }
    if !info.has(b"CreationDate") {
        info.set("CreationDate", now);
    }
}

fn utf8(bytes: &[u8]) -> Result<&str> {
    std::str::from_utf8(bytes).map_err(|_| Error::generic("text is not UTF-8"))
}

/// `out[0]` = a `Bytes` address (UTF-8), or `ERR_NOT_FOUND` when unset.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_meta_get(handle: *const c_void, key: *const u8, key_len: i64, out: *mut i64) -> i32 {
    call(|| {
        let key = slice(key, key_len)?;
        with_doc(handle, |d| match get(&d.pdf, key)? {
            Some(text) => {
                write_out(out, bytes_into_raw(text.into_bytes()));
                Ok(OK)
            }
            None => Ok(ERR_NOT_FOUND),
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_meta_set(
    handle: *const c_void,
    key: *const u8,
    key_len: i64,
    value: *const u8,
    value_len: i64,
    mode: i32,
) -> i32 {
    call(|| {
        let key = slice(key, key_len)?;
        let value = utf8(slice(value, value_len)?)?;
        with_doc(handle, |d| set(&mut d.pdf, key, value, mode).map(|_| OK))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::create;

    #[test]
    fn text_round_trip() {
        let mut d = create(false, b"");
        set(&mut d.pdf, b"Title", "Hello 世界 😀", MODE_TEXT).unwrap();
        assert_eq!(get(&d.pdf, b"Title").unwrap().unwrap(), "Hello 世界 😀");
        assert_eq!(get(&d.pdf, b"Author").unwrap(), None);
        set(&mut d.pdf, b"Lang", "en-US", MODE_LITERAL).unwrap();
        assert_eq!(get(&d.pdf, b"Lang").unwrap().unwrap(), "en-US");
    }

    #[test]
    fn pdf_doc_encoding() {
        assert_eq!(decode_text(b"a\x80\xa0\x18"), "a\u{2022}\u{20AC}\u{02D8}");
        assert_eq!(decode_text(&[0xff, 0xfe, b'h', 0, b'i', 0]), "hi");
    }

    #[test]
    fn update_info_keeps_creator() {
        let mut d = create(false, b"");
        set(&mut d.pdf, b"Creator", "me", MODE_TEXT).unwrap();
        update_info(&mut d.pdf, b"D:20200101000000Z");
        assert_eq!(get(&d.pdf, b"Creator").unwrap().unwrap(), "me");
        assert_eq!(get(&d.pdf, b"Producer").unwrap().unwrap(), PRODUCER);
        assert_eq!(get(&d.pdf, b"CreationDate").unwrap().unwrap(), "D:20200101000000Z");
    }

    #[test]
    fn show_title_sets_viewer_prefs() {
        let mut d = create(false, b"");
        set(&mut d.pdf, b"Title", "t", MODE_TEXT | FLAG_SHOW_TITLE).unwrap();
        let cat = d.pdf.catalog().unwrap();
        let prefs = cat.get(b"ViewerPreferences").unwrap().as_dict().unwrap();
        assert_eq!(prefs.get(b"DisplayDocTitle").unwrap(), &Object::Boolean(true));
    }
}
