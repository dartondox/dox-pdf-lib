//! The 14 standard fonts: metrics, WinAnsi / Symbol / ZapfDingbats encoding,
//! text width and the font dict, like pdf-lib's `StandardFontEmbedder`.
//!
//! The metrics come from `fonts.bin`, made from @pdf-lib/standard-fonts by
//! `tool/crosscheck/gen_fonts.mjs`, so widths match pdf-lib exactly.
//!
//! `Embedded` is any font of a document, standard or custom
//! (custom_font.rs). Other areas (eg. form fields) use `embedded` to get
//! the width and the encoding of a text in any font.

use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::{Arc, OnceLock};

use lopdf::{Dictionary, Object, ObjectId};

use crate::custom_font::{CustomFont, FontFile, parse_features};
use crate::document::{ref_from_i64, ref_to_i64};
use crate::ffi_util::*;

static DATA: &[u8] = include_bytes!("fonts.bin");

const ENCODING_NAMES: [&str; 3] = ["WinAnsi", "Symbol", "ZapfDingbats"];

/// The font names, in the order of Dart's `StandardFonts`.
pub const FONT_COUNT: usize = 14;

pub struct Encoding {
    /// unicode -> (code, glyph id)
    map: HashMap<u32, (u8, u16)>,
    /// sorted, like pdf-lib's `supportedCodePoints`
    code_points: Vec<u32>,
}

pub struct Font {
    pub name: String,
    pub encoding: usize,
    bbox: [f64; 4],
    ascender: f64,
    descender: f64,
    widths: HashMap<u16, u16>,
    kerns: HashMap<(u16, u16), i16>,
}

struct Data {
    encodings: Vec<Encoding>,
    fonts: Vec<Font>,
}

struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn bytes(&mut self, n: usize) -> &[u8] {
        let b = &self.data[self.pos..self.pos + n];
        self.pos += n;
        b
    }
    fn u8(&mut self) -> u8 {
        self.bytes(1)[0]
    }
    fn u16(&mut self) -> u16 {
        u16::from_le_bytes(self.bytes(2).try_into().unwrap())
    }
    fn i16(&mut self) -> i16 {
        self.u16() as i16
    }
    fn u32(&mut self) -> u32 {
        u32::from_le_bytes(self.bytes(4).try_into().unwrap())
    }
}

fn data() -> &'static Data {
    static CELL: OnceLock<Data> = OnceLock::new();
    CELL.get_or_init(|| {
        let mut r = Reader { data: DATA, pos: 0 };
        let encodings = (0..3)
            .map(|_| {
                let n = r.u16() as usize;
                let mut map = HashMap::with_capacity(n);
                let mut code_points = Vec::with_capacity(n);
                for _ in 0..n {
                    let cp = r.u32();
                    let code = r.u8();
                    map.insert(cp, (code, r.u16()));
                    code_points.push(cp);
                }
                Encoding { map, code_points }
            })
            .collect();
        let fonts = (0..FONT_COUNT)
            .map(|_| {
                let encoding = r.u8() as usize;
                let len = r.u8() as usize;
                let name = String::from_utf8_lossy(r.bytes(len)).into_owned();
                let bbox = [r.i16(), r.i16(), r.i16(), r.i16()].map(f64::from);
                let ascender = r.i16() as f64;
                let descender = r.i16() as f64;
                let widths = (0..r.u16()).map(|_| (r.u16(), r.u16())).collect();
                let kerns = (0..r.u16()).map(|_| ((r.u16(), r.u16()), r.i16())).collect();
                Font {
                    name,
                    encoding,
                    bbox,
                    ascender,
                    descender,
                    widths,
                    kerns,
                }
            })
            .collect();
        Data { encodings, fonts }
    })
}

pub fn font(id: i32) -> Result<&'static Font> {
    usize::try_from(id)
        .ok()
        .and_then(|i| data().fonts.get(i))
        .ok_or_else(|| Error::generic(format!("unknown standard font {id}")))
}

impl Font {
    fn encoding(&self) -> &'static Encoding {
        &data().encodings[self.encoding]
    }

    /// pdf-lib's `encodeTextAsGlyphs`: (code, glyph id) per code point.
    pub fn glyphs(&self, text: &str) -> Result<Vec<(u8, u16)>> {
        let enc = self.encoding();
        text.chars()
            .map(|c| {
                enc.map.get(&(c as u32)).copied().ok_or_else(|| {
                    Error::generic(format!(
                        "{} cannot encode \"{c}\" (0x{:04x})",
                        ENCODING_NAMES[self.encoding], c as u32
                    ))
                })
            })
            .collect()
    }

    /// pdf-lib's `widthOfTextAtSize`, with kerning. The same float steps,
    /// so the result is the same to the last bit.
    pub fn width_of_glyphs(&self, glyphs: &[(u8, u16)], size: f64) -> f64 {
        let mut total = 0.0;
        for (i, (_, g)) in glyphs.iter().enumerate() {
            let kern = glyphs
                .get(i + 1)
                .and_then(|(_, next)| self.kerns.get(&(*g, *next)))
                .copied()
                .unwrap_or(0);
            // a missing or 0 width counts as 250, like pdf-lib (`|| 250`)
            let width = match self.widths.get(g) {
                Some(&w) if w != 0 => w,
                _ => 250,
            };
            total += width as f64 + kern as f64;
        }
        total * (size / 1000.0)
    }

    pub fn width_of_text(&self, text: &str, size: f64) -> Result<f64> {
        Ok(self.width_of_glyphs(&self.glyphs(text)?, size))
    }

    /// `[top, bottom, descender]` as pdf-lib's height math uses them.
    pub fn vertical(&self) -> [f64; 3] {
        let top = if self.ascender != 0.0 {
            self.ascender
        } else {
            self.bbox[3]
        };
        let bottom = if self.descender != 0.0 {
            self.descender
        } else {
            self.bbox[1]
        };
        [top, bottom, self.descender]
    }

    pub fn code_points(&self) -> &'static [u32] {
        &self.encoding().code_points
    }
}

/// The font dict, like `StandardFontEmbedder.embedIntoContext`.
pub fn embed(pdf: &mut lopdf::Document, id: i32, custom_name: Option<&[u8]>) -> Result<ObjectId> {
    let f = font(id)?;
    let mut dict = Dictionary::new();
    dict.set("Type", Object::Name(b"Font".to_vec()));
    dict.set("Subtype", Object::Name(b"Type1".to_vec()));
    let base = custom_name.filter(|n| !n.is_empty()).unwrap_or(f.name.as_bytes());
    dict.set("BaseFont", Object::Name(base.to_vec()));
    if f.encoding == 0 {
        dict.set("Encoding", Object::Name(b"WinAnsiEncoding".to_vec()));
    }
    Ok(pdf.add_object(Object::Dictionary(dict)))
}

/// A font embedded in a document.
#[derive(Clone)]
pub enum Embedded {
    /// The index of the standard font.
    Standard(i32),
    Custom(Box<CustomFont>),
}

/// The fonts of a document: font ref -> font. Part of `Doc`.
pub type Fonts = HashMap<ObjectId, Embedded>;

/// The font `id` of the document.
pub fn embedded(fonts: &mut Fonts, id: ObjectId) -> Result<&mut Embedded> {
    fonts
        .get_mut(&id)
        .ok_or_else(|| Error::generic("the font is not embedded in this document"))
}

impl Embedded {
    /// pdf-lib's `PDFFont.name`, also the tag of its page resource name.
    pub fn name(&self) -> Result<&str> {
        Ok(match self {
            Embedded::Standard(i) => &font(*i)?.name,
            Embedded::Custom(c) => &c.file.name,
        })
    }

    /// pdf-lib's `encodeText`, as hex digits without the `<>`. A subset
    /// font keeps the glyphs for save.
    pub fn encode(&mut self, text: &str) -> Result<Vec<u8>> {
        match self {
            Embedded::Standard(i) => {
                let glyphs = font(*i)?.glyphs(text)?;
                let mut hex = Vec::with_capacity(glyphs.len() * 2);
                for (code, _) in glyphs {
                    hex.extend_from_slice(format!("{code:02X}").as_bytes());
                }
                Ok(hex)
            }
            Embedded::Custom(c) => c.encode(text),
        }
    }

    /// The operators that show `text` (for drawText and other areas), like
    /// pdf-lib's `<hex> Tj`. See `CustomFont::show_text`.
    pub fn show_text(&mut self, text: &str, size: f64) -> Result<Vec<u8>> {
        match self {
            Embedded::Standard(_) => {
                let mut out = vec![b'<'];
                out.extend(self.encode(text)?);
                out.extend_from_slice(b"> Tj");
                Ok(out)
            }
            Embedded::Custom(c) => c.show_text(text, size),
        }
    }

    /// Where a line may break without splitting a letter from its marks:
    /// `true` per char, before it. Every char for a standard font.
    pub fn break_points(&self, text: &str) -> Result<Vec<bool>> {
        match self {
            Embedded::Standard(_) => Ok(vec![true; text.chars().count()]),
            Embedded::Custom(c) => c.break_points(text),
        }
    }

    /// pdf-lib's `widthOfTextAtSize`.
    pub fn width_of_text(&mut self, text: &str, size: f64) -> Result<f64> {
        match self {
            Embedded::Standard(i) => font(*i)?.width_of_text(text, size),
            Embedded::Custom(c) => c.width_of_text(text, size),
        }
    }

    /// `[top, bottom, descender]`: height = top - bottom, without the
    /// descender it is height + descender (see PDFFont in Dart).
    #[allow(dead_code)] // for other areas, eg. the font size of a form field
    pub fn vertical(&self) -> Result<[f64; 3]> {
        Ok(match self {
            Embedded::Standard(i) => font(*i)?.vertical(),
            Embedded::Custom(c) => c.file.vertical(),
        })
    }

    pub fn code_points(&self) -> Result<&[u32]> {
        Ok(match self {
            Embedded::Standard(i) => font(*i)?.code_points(),
            Embedded::Custom(c) => c.file.code_points(),
        })
    }
}

/// Save: writes the objects of the custom fonts into `pdf`, the copy that
/// is written (pdf-lib embeds fonts at save too).
pub fn write_fonts(fonts: &Fonts, pdf: &mut lopdf::Document) -> Result<()> {
    for (id, f) in fonts {
        if let Embedded::Custom(c) = f {
            c.write(pdf, *id)?;
        }
    }
    Ok(())
}

fn text_arg<'a>(ptr: *const u8, len: i64) -> Result<&'a str> {
    std::str::from_utf8(slice(ptr, len)?).map_err(|_| Error::generic("text is not UTF-8"))
}

// ---------------------------------------------------------------- exports

/// Embeds standard font `font` (with an optional custom `BaseFont`).
/// `out[0]` = the font ref.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_embed_standard_font(
    handle: *const c_void,
    font: i32,
    name: *const u8,
    name_len: i64,
    out: *mut i64,
) -> i32 {
    call(|| {
        let custom = slice(name, name_len)?;
        with_doc(handle, |d| {
            let id = embed(&mut d.pdf, font, Some(custom))?;
            d.fonts.insert(id, Embedded::Standard(font));
            write_out(out, ref_to_i64(id));
            Ok(OK)
        })
    })
}

/// `out[0]` = the width of `text` at `size`.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_font_width(font: i32, text: *const u8, len: i64, size: f64, out: *mut f64) -> i32 {
    call(|| {
        let w = self::font(font)?.width_of_text(text_arg(text, len)?, size)?;
        // SAFETY: Dart passes room for one double.
        unsafe { *out = w };
        Ok(OK)
    })
}

/// `out` = top, bottom, descender (see `Font::vertical`).
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_font_vertical(font: i32, out: *mut f64) -> i32 {
    call(|| {
        let v = self::font(font)?.vertical();
        for (i, x) in v.iter().enumerate() {
            // SAFETY: Dart passes room for 3 doubles.
            unsafe { *out.add(i) = *x };
        }
        Ok(OK)
    })
}

/// The supported code points into `out` (room for `cap`). `count[0]` = how
/// many there are; when more than `cap`, Dart calls again with more room.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_font_charset(font: i32, out: *mut i64, cap: i64, count: *mut i64) -> i32 {
    call(|| {
        let cps = self::font(font)?.code_points();
        write_out(count, cps.len() as i64);
        if cps.len() as i64 <= cap && !out.is_null() {
            for (i, cp) in cps.iter().enumerate() {
                // SAFETY: Dart passes room for `cap` values.
                unsafe { *out.add(i) = *cp as i64 };
            }
        }
        Ok(OK)
    })
}

/// `out[0]` = a `Bytes` address of the hex codes of `text` (pdf-lib's
/// `encodeText`, without the `<>`).
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_font_encode(font: i32, text: *const u8, len: i64, out: *mut i64) -> i32 {
    call(|| {
        let glyphs = self::font(font)?.glyphs(text_arg(text, len)?)?;
        let mut hex = Vec::with_capacity(glyphs.len() * 2);
        for (code, _) in glyphs {
            hex.extend_from_slice(format!("{code:02X}").as_bytes());
        }
        write_out(out, bytes_into_raw(hex));
        Ok(OK)
    })
}

/// Embeds a TrueType or OpenType font file, like pdf-lib's `embedFont`.
/// `features`: see `parse_features`. `out[0]` = the font ref, `out[1]` = a
/// `Bytes` address of the font name, `vertical` = see `Embedded::vertical`.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn dox_pdf_embed_font(
    handle: *const c_void,
    data: *const u8,
    data_len: i64,
    subset: i32,
    name: *const u8,
    name_len: i64,
    features: *const u8,
    features_len: i64,
    out: *mut i64,
    vertical: *mut f64,
) -> i32 {
    call(|| {
        let file = Arc::new(FontFile::parse(slice(data, data_len)?.to_vec())?);
        let custom = String::from_utf8_lossy(slice(name, name_len)?).into_owned();
        let features = parse_features(slice(features, features_len)?);
        // a new object: other documents' embed caches must see it
        with_doc_mut(handle, |d| {
            // the name is unique in the file; pdf-lib adds a random number
            let base = if custom.is_empty() {
                format!("{}-{}", file.name, d.fonts.len() + 1)
            } else {
                custom
            };
            let font = CustomFont::new(file, subset != 0, base, features);
            // the font dict is written at save, at this ref (pdf-lib's `nextRef`)
            let id = d.pdf.add_object(Object::Null);
            let v = font.file.vertical();
            write_out(out, ref_to_i64(id));
            // SAFETY: Dart passes room for 2 i64 and 3 doubles.
            unsafe {
                *out.add(1) = bytes_into_raw(font.file.name.as_bytes().to_vec());
                for (i, x) in v.iter().enumerate() {
                    *vertical.add(i) = *x;
                }
            }
            d.fonts.insert(id, Embedded::Custom(Box::new(font)));
            Ok(OK)
        })
    })
}

/// `out[0]` = the width of `text` at `size` in the document's font `font`.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_doc_font_width(
    handle: *const c_void,
    font: i64,
    text: *const u8,
    len: i64,
    size: f64,
    out: *mut f64,
) -> i32 {
    call(|| {
        let text = text_arg(text, len)?;
        let w = with_doc(handle, |d| {
            embedded(&mut d.fonts, ref_from_i64(font))?.width_of_text(text, size)
        })?;
        // SAFETY: Dart passes room for one double.
        unsafe { *out = w };
        Ok(OK)
    })
}

/// `out[0]` = a `Bytes` address of the hex codes of `text` in the
/// document's font `font`.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_doc_font_encode(
    handle: *const c_void,
    font: i64,
    text: *const u8,
    len: i64,
    out: *mut i64,
) -> i32 {
    call(|| {
        let text = text_arg(text, len)?;
        let hex = with_doc(handle, |d| embedded(&mut d.fonts, ref_from_i64(font))?.encode(text))?;
        write_out(out, bytes_into_raw(hex));
        Ok(OK)
    })
}

/// Like `dox_pdf_font_charset`, for the document's font `font`.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_doc_font_charset(
    handle: *const c_void,
    font: i64,
    out: *mut i64,
    cap: i64,
    count: *mut i64,
) -> i32 {
    call(|| {
        with_doc(handle, |d| {
            let cps = embedded(&mut d.fonts, ref_from_i64(font))?.code_points()?;
            write_out(count, cps.len() as i64);
            if cps.len() as i64 <= cap && !out.is_null() {
                for (i, cp) in cps.iter().enumerate() {
                    // SAFETY: Dart passes room for `cap` values.
                    unsafe { *out.add(i) = *cp as i64 };
                }
            }
            Ok(OK)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const HELVETICA: i32 = 4;

    #[test]
    fn widths_match_pdf_lib() {
        let f = font(HELVETICA).unwrap();
        assert_eq!(f.name, "Helvetica");
        // values from pdf-lib 1.17.1
        assert_eq!(f.width_of_text("Hello", 24.0).unwrap(), 54.672000000000004);
        // "AV" has a kern pair (-70)
        assert_eq!(f.width_of_text("AV", 1000.0).unwrap(), 667.0 + 667.0 - 70.0);
        assert_eq!(font(0).unwrap().width_of_text("abc", 10.0).unwrap(), 18.0);
    }

    #[test]
    fn unencodable_char_is_an_error() {
        let e = font(HELVETICA).unwrap().glyphs("a\u{4e16}").unwrap_err();
        assert_eq!(e.message, "WinAnsi cannot encode \"\u{4e16}\" (0x4e16)");
    }

    #[test]
    fn vertical_metrics() {
        assert_eq!(font(HELVETICA).unwrap().vertical(), [718.0, -207.0, -207.0]);
        // Symbol has no ascender: the bbox is used
        assert_eq!(font(12).unwrap().vertical(), [1010.0, -293.0, 0.0]);
    }
}
