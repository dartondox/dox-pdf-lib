//! Custom fonts (TrueType and OpenType/CFF), like pdf-lib's
//! `CustomFontEmbedder` and `CustomFontSubsetEmbedder` with @pdf-lib/fontkit.
//!
//! - The font is parsed once, at `embedFont`. Widths, the cmap and the
//!   metrics are read into plain tables then, so a width is a table lookup.
//! - Text layout (ligatures and other GSUB features) uses harfrust (a port of
//!   HarfBuzz). The result is made to match fontkit's `layout()`: the same
//!   glyph ids, and the width is the sum of the hmtx advances (pdf-lib does
//!   not add kerning).
//! - The font objects (Type0 / CIDFont / descriptor / font file / ToUnicode)
//!   are written at save, like pdf-lib. A subset is made then.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use harfrust::{
    Buffer, BufferFlags, ClusterLevel, Direction, Feature, FontFuncs, GlyphId, Script, ShapeOptions, ShapePlan,
    ShaperFont, Tag,
};
use lopdf::{Dictionary, Object, ObjectId, Stream, StringFormat};
use read_fonts::tables::cmap::CmapSubtable;
use read_fonts::{FontRef, TableProvider};

use crate::document::num;
use crate::draw::deflate;
use crate::ffi_util::*;

type Plans = Arc<Mutex<HashMap<(Direction, Option<Script>), Arc<ShapePlan>>>>;

/// What is read from the font file, once. Shared by all copies of a
/// document (`Doc` is cloned).
pub struct FontFile {
    data: Arc<Vec<u8>>,
    font: harfrust::Font,
    /// fontkit's `postscriptName || 'Font'`
    pub name: String,
    upem: f64,
    advances: Vec<u16>,
    cmap: HashMap<u32, u16>,
    /// fontkit's `characterSet`, in its order
    charset: Vec<u32>,
    ascent: f64,
    descent: f64,
    /// head: minX, minY, maxX, maxY
    bbox: [f64; 4],
    cap_height: f64,
    x_height: f64,
    italic_angle: f64,
    flags: i64,
    cff: bool,
    gsub: bool,
    /// The full font file, compressed on the first save.
    packed: OnceLock<Vec<u8>>,
}

/// An embedded custom font of one document.
pub struct CustomFont {
    pub file: Arc<FontFile>,
    subset: bool,
    base_name: String,
    features: Arc<Vec<Feature>>,
    plans: Plans,
    /// Behind a lock, so a font handle of another area (eg. a form field,
    /// see `share`) adds its glyphs to this font.
    glyphs: Arc<Mutex<Glyphs>>,
}

#[derive(Clone, Default)]
struct Glyphs {
    /// fontkit keeps one `Glyph` object per glyph id, with the code points
    /// of the first use. The ToUnicode CMap uses them, so we keep the same.
    code_points: HashMap<u16, Vec<u32>>,
    /// Subset: the glyphs in the order of first use. 0 is `.notdef`.
    remapper: subsetter::GlyphRemapper,
}

/// A copy of the document has its own glyphs.
impl Clone for CustomFont {
    fn clone(&self) -> Self {
        let glyphs = self.glyphs.lock().map(|g| g.clone()).unwrap_or_default();
        CustomFont {
            glyphs: Arc::new(Mutex::new(glyphs)),
            ..self.share()
        }
    }
}

/// From DerivedCoreProperties.txt, minus U+115F, U+1160, U+3164 and U+FFA0,
/// as fontkit's `isDefaultIgnorable` has it.
fn is_default_ignorable(ch: u32) -> bool {
    match ch >> 16 {
        0 => match ch >> 8 {
            0x00 => ch == 0x00AD,
            0x03 => ch == 0x034F,
            0x06 => ch == 0x061C,
            0x17 => (0x17B4..=0x17B5).contains(&ch),
            0x18 => (0x180B..=0x180E).contains(&ch),
            0x20 => {
                (0x200B..=0x200F).contains(&ch) || (0x202A..=0x202E).contains(&ch) || (0x2060..=0x206F).contains(&ch)
            }
            0xFE => (0xFE00..=0xFE0F).contains(&ch) || ch == 0xFEFF,
            0xFF => (0xFFF0..=0xFFF8).contains(&ch),
            _ => false,
        },
        0x01 => (0x1BCA0..=0x1BCA3).contains(&ch) || (0x1D173..=0x1D17A).contains(&ch),
        0x0E => (0xE0000..=0xE0FFF).contains(&ch),
        _ => false,
    }
}

fn is_variation_selector(c: u32) -> bool {
    (0xFE00..=0xFE0F).contains(&c) || (0xE0100..=0xE01EF).contains(&c)
}

/// Scripts that fontkit can not lay out like HarfBuzz (it has no shaper
/// for them, or its shaper differs). Their text is laid out by HarfBuzz's
/// rules, and drawn with HarfBuzz's positions.
fn is_complex(s: Script) -> bool {
    matches!(
        s,
        Script::ARABIC
            | Script::SYRIAC
            | Script::NKO
            | Script::MONGOLIAN
            | Script::THAANA
            | Script::HEBREW
            | Script::THAI
            | Script::LAO
            | Script::MYANMAR
            | Script::KHMER
            | Script::TIBETAN
            | Script::DEVANAGARI
            | Script::BENGALI
            | Script::GURMUKHI
            | Script::GUJARATI
            | Script::ORIYA
            | Script::TAMIL
            | Script::TELUGU
            | Script::KANNADA
            | Script::MALAYALAM
            | Script::SINHALA
            | Script::BALINESE
            | Script::JAVANESE
            | Script::SUNDANESE
            | Script::TAI_THAM
            | Script::TAI_VIET
            | Script::CHAM
            | Script::BUGINESE
            | Script::BATAK
    )
}

/// A run of one direction and one script, in bytes of the text.
#[derive(Debug, PartialEq)]
struct Run {
    start: usize,
    end: usize,
    script: Script,
    rtl: bool,
}

fn is_weak(s: Script) -> bool {
    matches!(s, Script::COMMON | Script::INHERITED | Script::UNKNOWN)
}

/// `text` as runs in drawn order (left to right). The direction comes from
/// the Unicode bidi algorithm (UAX #9), so numbers and Latin words in a
/// right-to-left text run left to right. Each direction run is split by
/// script; spaces, digits and punctuation take the script next to them.
fn runs(text: &str) -> Vec<Run> {
    let info = unicode_bidi::ParagraphBidiInfo::new(text, None);
    let (levels, bidi_runs) = info.visual_runs(0..text.len());
    let strong = |c: char| Some(harfrust::unicode::script(c as u32)).filter(|s| !is_weak(*s));
    let mut out = Vec::new();
    for range in bidi_runs {
        let rtl = levels[range.start].is_rtl();
        // a run of only weak characters: the script before it, else after
        let near = text[..range.start]
            .chars()
            .rev()
            .find_map(strong)
            .or_else(|| text[range.end..].chars().find_map(strong))
            .unwrap_or(Script::COMMON);
        let mut sub: Vec<Run> = Vec::new();
        for (i, c) in text[range.clone()].char_indices() {
            let (i, end) = (range.start + i, range.start + i + c.len_utf8());
            match (sub.last_mut(), strong(c)) {
                (Some(r), None) => r.end = end,
                (Some(r), Some(s)) if r.script == s => r.end = end,
                // weak characters before the first letter take its script
                (Some(r), Some(s)) if r.script == Script::COMMON => {
                    r.end = end;
                    r.script = s;
                }
                (_, s) => sub.push(Run {
                    start: i,
                    end,
                    script: s.unwrap_or(Script::COMMON),
                    rtl,
                }),
            }
        }
        for r in sub.iter_mut().filter(|r| r.script == Script::COMMON) {
            r.script = near;
        }
        if rtl {
            sub.reverse();
        }
        out.extend(sub);
    }
    out
}

/// The glyphs of a text, and for a complex script HarfBuzz's positions:
/// `[x advance, x offset, y offset]` in font units.
pub struct Layout {
    pub glyphs: Vec<u16>,
    pub pos: Option<Vec<[i32; 3]>>,
    /// `(glyph count, text)` per ActualText span, in drawn order.
    pub spans: Option<Vec<(usize, String)>>,
}

fn bad(e: impl std::fmt::Display) -> Error {
    Error::generic(format!("can not read the font: {e}"))
}

/// fontkit's `CmapProcessor`: the first table of this list, then all its
/// code points (the `characterSet`) and glyph ids (`lookup`).
fn read_cmap(font: &FontRef) -> Result<(HashMap<u32, u16>, Vec<u32>)> {
    let cmap = font.cmap().map_err(bad)?;
    let pairs = [(3, 10), (0, 6), (0, 4), (3, 1), (0, 3), (0, 2), (0, 1), (0, 0)];
    let record = pairs
        .iter()
        .find_map(|&(p, e)| {
            cmap.encoding_records()
                .iter()
                .find(|r| r.platform_id() as u16 == p && r.encoding_id() == e)
        })
        .ok_or_else(|| Error::generic("Could not find a supported cmap table"))?;
    let table = record.subtable(cmap.offset_data()).map_err(bad)?;
    let mut map = HashMap::new();
    let mut charset = Vec::new();
    // a range is added at once; overlapping ranges in a broken or hostile
    // font could add far more code points than Unicode has
    let mut room = 0x110000usize;
    let mut fits = |n: u64| -> Result<()> {
        room = room
            .checked_sub(usize::try_from(n).unwrap_or(usize::MAX))
            .ok_or_else(|| Error::generic("can not read the font: the cmap is too big"))?;
        Ok(())
    };
    let mut add = |c: u32, gid: u32| {
        map.entry(c).or_insert(gid as u16);
        charset.push(c);
    };
    match table {
        CmapSubtable::Format0(t) => {
            for (c, g) in t.glyph_id_array().iter().enumerate() {
                add(c as u32, *g as u32);
            }
        }
        CmapSubtable::Format4(t) => {
            let (ends, starts, deltas, offsets, ids) = (
                t.end_code(),
                t.start_code(),
                t.id_delta(),
                t.id_range_offsets(),
                t.glyph_id_array(),
            );
            let seg_count = ends.len();
            for (i, end) in ends.iter().enumerate() {
                let (start, end) = (starts.get(i).map_or(0, |v| v.get()) as u32, end.get() as u32);
                let delta = deltas.get(i).map_or(0, |v| v.get()) as i32;
                let range_offset = offsets.get(i).map_or(0, |v| v.get()) as i64;
                fits((end + 1).saturating_sub(start) as u64)?;
                for c in start..=end {
                    let gid = if range_offset == 0 {
                        c as i32 + delta
                    } else {
                        let index = range_offset / 2 + (c - start) as i64 - (seg_count - i) as i64;
                        let g = usize::try_from(index)
                            .ok()
                            .and_then(|x| ids.get(x))
                            .map_or(0, |v| v.get()) as i32;
                        if g != 0 { g + delta } else { 0 }
                    };
                    add(c, (gid & 0xffff) as u32);
                }
            }
        }
        CmapSubtable::Format6(t) => {
            let first = t.first_code() as u32;
            for (i, g) in t.glyph_id_array().iter().enumerate() {
                add(first + i as u32, g.get() as u32);
            }
        }
        CmapSubtable::Format10(t) => {
            let first = t.start_char_code();
            for (i, g) in t.glyph_id_array().iter().enumerate() {
                add(first + i as u32, g.get() as u32);
            }
        }
        CmapSubtable::Format12(t) => {
            for g in t.groups() {
                let end = g.end_char_code().min(0x10FFFF);
                fits((end as u64 + 1).saturating_sub(g.start_char_code() as u64))?;
                for c in g.start_char_code()..=end {
                    add(c, g.start_glyph_id().wrapping_add(c - g.start_char_code()));
                }
            }
        }
        CmapSubtable::Format13(t) => {
            for g in t.groups() {
                let end = g.end_char_code().min(0x10FFFF);
                fits((end as u64 + 1).saturating_sub(g.start_char_code() as u64))?;
                for c in g.start_char_code()..=end {
                    add(c, g.glyph_id());
                }
            }
        }
        _ => return Err(Error::generic("unsupported cmap format")),
    }
    Ok((map, charset))
}

/// fontkit's `postscriptName`: name id 6, the first language found, the
/// last record of that language.
fn postscript_name(font: &FontRef) -> Option<String> {
    let name = font.name().ok()?;
    let data = name.string_data();
    let key = |r: &read_fonts::tables::name::NameRecord| match (r.platform_id(), r.language_id()) {
        (1, 0) | (3, 0x409) => (u16::MAX, 0),
        other => other,
    };
    let records: Vec<_> = name
        .name_record()
        .iter()
        .filter(|r| r.name_id().to_u16() == 6)
        .collect();
    let first = key(records.first()?);
    let record = records.iter().rev().find(|r| key(r) == first)?;
    Some(record.string(data).ok()?.chars().collect())
}

impl FontFile {
    pub fn parse(data: Vec<u8>) -> Result<FontFile> {
        // one copy of the bytes, shared with harfrust
        let data = Arc::new(data);
        let font = FontRef::new(&data).map_err(bad)?;
        let head = font.head().map_err(bad)?;
        let hhea = font.hhea().map_err(bad)?;
        let num_glyphs = font.maxp().map_err(bad)?.num_glyphs() as usize;
        let hmtx = font.hmtx().map_err(bad)?;
        let metrics = hmtx.h_metrics();
        let last = metrics.last().map_or(0, |m| m.advance());
        let advances = (0..num_glyphs.max(metrics.len()))
            .map(|g| metrics.get(g).map_or(last, |m| m.advance()))
            .collect();
        let (cmap, charset) = read_cmap(&font)?;
        let os2 = font.os2().ok();
        let post = font.post().ok();
        let ascent = hhea.ascender().to_i16() as f64;
        let family_class = os2.as_ref().map_or(0, |o| o.s_family_class());
        let mut flags = 1 << 2; // symbolic, always
        if post.as_ref().is_some_and(|p| p.is_fixed_pitch() != 0) {
            flags |= 1;
        }
        if (1..=7).contains(&family_class) {
            flags |= 1 << 1;
        }
        if family_class == 10 {
            flags |= 1 << 3;
        }
        if head.mac_style().contains(read_fonts::tables::head::MacStyle::ITALIC) {
            flags |= 1 << 6;
        }
        let cff = font.table_data(Tag::new(b"CFF ")).is_some();
        if !cff && font.table_data(Tag::new(b"glyf")).is_none() {
            return Err(Error::generic("only TrueType and OpenType/CFF fonts can be embedded"));
        }
        let file = FontFile {
            name: postscript_name(&font).unwrap_or_else(|| "Font".into()),
            upem: head.units_per_em() as f64,
            advances,
            cmap,
            charset,
            ascent,
            descent: hhea.descender().to_i16() as f64,
            bbox: [head.x_min(), head.y_min(), head.x_max(), head.y_max()].map(f64::from),
            // fontkit: OS/2 capHeight (from version 2), else the ascent
            cap_height: match &os2 {
                Some(o) => o.s_cap_height().unwrap_or(0) as f64,
                None => ascent,
            },
            x_height: os2.as_ref().and_then(|o| o.sx_height()).unwrap_or(0) as f64,
            italic_angle: post.as_ref().map_or(0.0, |p| p.italic_angle().to_f64()),
            flags,
            cff,
            gsub: font.table_data(Tag::new(b"GSUB")).is_some(),
            packed: OnceLock::new(),
            font: harfrust::Font::new(
                read_fonts::model::Blob::from(data.clone() as Arc<dyn AsRef<[u8]> + Send + Sync>),
                0,
            )
            .ok_or_else(|| Error::generic("can not read the font"))?,
            data,
        };
        Ok(file)
    }

    fn scale(&self) -> f64 {
        1000.0 / self.upem
    }

    fn glyph(&self, c: u32) -> u16 {
        self.cmap.get(&c).copied().unwrap_or(0)
    }

    fn advance(&self, gid: u16) -> f64 {
        self.advances.get(gid as usize).copied().unwrap_or(0) as f64
    }

    /// `[top, bottom, descender]` for the height math in Dart, as pdf-lib's
    /// `heightOfFontAtSize` (it takes the raw descent off, not the scaled
    /// one) and `sizeOfFontAtHeight` compute them.
    pub fn vertical(&self) -> [f64; 3] {
        let or = |a: f64, b: f64| if a != 0.0 { a } else { b };
        [
            or(self.ascent, self.bbox[3]) * self.scale(),
            or(self.descent, self.bbox[1]) * self.scale(),
            -self.descent.abs(),
        ]
    }

    pub fn code_points(&self) -> &[u32] {
        &self.charset
    }
}

/// harfrust looks up glyphs here: fontkit's cmap. A missing glyph is
/// `.notdef`, like fontkit, so harfrust does not try other characters
/// (decomposition, other spaces).
struct Funcs<'a>(&'a FontFile);

impl FontFuncs for Funcs<'_> {
    fn nominal_glyph(&self, _: &ShaperFont, c: u32) -> Option<GlyphId> {
        Some(GlyphId::new(self.0.glyph(c) as u32))
    }
}

/// The fonts read so far in this process, for `load`. Weak, so a font is
/// freed when no document uses it any more.
static LOADED: Mutex<Vec<(u64, std::sync::Weak<FontFile>)>> = Mutex::new(Vec::new());

/// A key for font bytes: the length and the first and last 256 KiB. A hit
/// is checked against all bytes, so a key that two fonts share is fine.
fn font_key(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    let part = 256 * 1024;
    bytes.len().hash(&mut h);
    bytes[..bytes.len().min(part)].hash(&mut h);
    bytes[bytes.len().saturating_sub(part)..].hash(&mut h);
    h.finish()
}

/// The font of `bytes`, read once per process: a server that embeds the
/// same font into many documents parses (and compresses) it once. Safe
/// from many threads (isolates).
pub fn load(bytes: &[u8]) -> Result<Arc<FontFile>> {
    let key = font_key(bytes);
    let lock = || LOADED.lock().unwrap_or_else(|e| e.into_inner());
    let hit = lock()
        .iter()
        .filter(|(k, _)| *k == key)
        .filter_map(|(_, w)| w.upgrade())
        .find(|f| f.data.as_slice() == bytes);
    if let Some(f) = hit {
        return Ok(f);
    }
    // parsed without the lock: other threads do not wait for a big font
    let file = Arc::new(FontFile::parse(bytes.to_vec())?);
    let mut loaded = lock();
    loaded.retain(|(_, w)| w.strong_count() > 0);
    loaded.push((key, Arc::downgrade(&file)));
    Ok(file)
}

/// `features` from Dart: a 4 byte tag and a 0/1 byte per feature.
pub fn parse_features(bytes: &[u8]) -> Vec<Feature> {
    bytes
        .as_chunks::<5>()
        .0
        .iter()
        .map(|c| Feature::new(Tag::new(&[c[0], c[1], c[2], c[3]]), c[4] as u32, ..))
        .collect()
}

impl CustomFont {
    pub fn new(file: Arc<FontFile>, subset: bool, base_name: String, features: Vec<Feature>) -> CustomFont {
        CustomFont {
            file,
            subset,
            base_name,
            features: Arc::new(features),
            plans: Arc::default(),
            glyphs: Arc::default(),
        }
    }

    /// The same font, with the same glyphs (not a copy of them).
    pub fn share(&self) -> CustomFont {
        CustomFont {
            file: self.file.clone(),
            subset: self.subset,
            base_name: self.base_name.clone(),
            features: self.features.clone(),
            plans: self.plans.clone(),
            glyphs: self.glyphs.clone(),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, Glyphs> {
        // a panic under the lock leaves the glyphs as they were: still fine
        self.glyphs.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// fontkit's `getGlyph(id, codePoints)`: the first code points win.
    fn get_glyph(&self, gid: u16, cps: Vec<u32>) -> u16 {
        self.state().code_points.entry(gid).or_insert(cps);
        gid
    }

    fn first_code_point(&self, gid: u16) -> Option<u32> {
        self.state().code_points.get(&gid).and_then(|c| c.first().copied())
    }

    /// harfrust's glyphs and clusters (byte offsets), in logical order.
    fn shape(&self, text: &str) -> Result<(Vec<(u16, usize)>, bool)> {
        let mut buffer = Buffer::new();
        buffer.push_str(text);
        buffer.guess_segment_properties();
        buffer.set_cluster_level(ClusterLevel::Characters);
        buffer.set_flags(BufferFlags::BEGINNING_OF_TEXT | BufferFlags::END_OF_TEXT);
        let key = (buffer.direction(), buffer.script());
        let plan = {
            let mut plans = self.plans.lock().map_err(|_| Error::generic("font cache is broken"))?;
            plans
                .entry(key)
                .or_insert_with(|| Arc::new(ShapePlan::new(&self.file.font, key.0, key.1, None, &self.features)))
                .clone()
        };
        let funcs = Funcs(&self.file);
        let font = ShaperFont::new(&self.file.font).with_font_funcs(Some(&funcs));
        let options = ShapeOptions::new().plan(Some(&plan)).features(&self.features);
        harfrust::shape(&font, &mut buffer, options)
            .map_err(|e| Error::generic(format!("can not lay out text: {e:?}")))?;
        let rtl = key.0 == Direction::RightToLeft;
        let mut out: Vec<(u16, usize)> = buffer
            .glyph_infos()
            .iter()
            .map(|g| (g.glyph_id as u16, g.cluster as usize))
            .collect();
        if rtl {
            out.reverse();
        }
        Ok((out, rtl))
    }

    /// The glyph of `chars` composed to one character, if they compose.
    fn composed(&self, chars: &[(usize, u32)]) -> Option<u16> {
        let mut c = chars.first()?.1;
        for &(_, m) in &chars[1..] {
            c = harfrust::unicode::compose(c, m)?;
        }
        Some(self.file.glyph(c))
    }

    /// The glyphs of `text`. Text of a complex script is laid out by
    /// harfrust as HarfBuzz does it, with positions; other text exactly like
    /// fontkit's `layout()`.
    pub fn layout(&self, text: &str) -> Result<Layout> {
        if text.chars().any(|c| is_complex(harfrust::unicode::script(c as u32))) {
            return self.layout_complex(text);
        }
        Ok(Layout {
            glyphs: self.layout_simple(text)?,
            pos: None,
            spans: None,
        })
    }

    /// The plan of a run, made once per direction and script.
    fn plan(&self, direction: Direction, script: Option<Script>) -> Result<Arc<ShapePlan>> {
        let mut plans = self.plans.lock().map_err(|_| Error::generic("font cache is broken"))?;
        Ok(plans
            .entry((direction, script))
            .or_insert_with(|| Arc::new(ShapePlan::new(&self.file.font, direction, script, None, &self.features)))
            .clone())
    }

    /// One run of one script, shaped by harfrust with its own font
    /// functions, so the result is HarfBuzz's (`hb-shape`).
    fn shape_run(&self, text: &str, run: &Run) -> Result<Buffer> {
        let mut buffer = Buffer::new();
        for (i, c) in text[run.start..run.end].char_indices() {
            buffer.push(c as u32, (run.start + i) as u32);
        }
        buffer.set_pre_context(&text[..run.start]);
        buffer.set_post_context(&text[run.end..]);
        buffer.set_script(Some(run.script));
        buffer.set_direction(if run.rtl {
            Direction::RightToLeft
        } else {
            Direction::LeftToRight
        });
        let plan = self.plan(buffer.direction(), buffer.script())?;
        let font = ShaperFont::new(&self.file.font);
        let options = ShapeOptions::new().plan(Some(&plan)).features(&self.features);
        harfrust::shape(&font, &mut buffer, options)
            .map_err(|e| Error::generic(format!("can not lay out text: {e:?}")))?;
        Ok(buffer)
    }

    fn layout_complex(&self, text: &str) -> Result<Layout> {
        let (mut glyphs, mut pos) = (Vec::new(), Vec::new());
        let mut spans: Vec<(usize, String)> = Vec::new();
        for run in runs(text) {
            let buffer = self.shape_run(text, &run)?;
            let infos = buffer.glyph_infos();
            let mut starts: Vec<usize> = infos.iter().map(|g| g.cluster as usize).collect();
            starts.sort_unstable();
            starts.dedup();
            let cluster_end = |cluster: usize| {
                starts
                    .get(starts.partition_point(|s| *s <= cluster))
                    .copied()
                    .unwrap_or(run.end)
            };
            let mut seen = std::collections::HashSet::new();
            let mut run_glyphs = Vec::with_capacity(infos.len());
            // the first glyph of a cluster gets the text of the cluster, in
            // text order: right to left, the base glyph is drawn after its
            // marks
            let order: Vec<usize> = if run.rtl {
                (0..infos.len()).rev().collect()
            } else {
                (0..infos.len()).collect()
            };
            for i in order {
                let cluster = infos[i].cluster as usize;
                let cps = if seen.insert(cluster) {
                    text[cluster..cluster_end(cluster)].chars().map(|c| c as u32).collect()
                } else {
                    Vec::new()
                };
                run_glyphs.push(self.get_glyph(infos[i].glyph_id as u16, cps));
            }
            if run.rtl {
                run_glyphs.reverse();
            }
            glyphs.extend(run_glyphs);
            pos.extend(
                buffer
                    .glyph_positions()
                    .iter()
                    .map(|p| [p.x_advance, p.x_offset, p.y_offset]),
            );
            // ActualText spans in drawn order: right to left one per
            // cluster (viewers turn the line around and would turn a longer
            // text too); left to right one per word, and one per space
            let mut last = usize::MAX;
            let mut word = false;
            for g in infos {
                let cluster = g.cluster as usize;
                if cluster == last {
                    if let Some(s) = spans.last_mut() {
                        s.0 += 1;
                    }
                    continue;
                }
                last = cluster;
                let t = &text[cluster..cluster_end(cluster)];
                let space = t.chars().all(char::is_whitespace);
                match spans.last_mut() {
                    Some(s) if !run.rtl && word && !space => {
                        s.0 += 1;
                        s.1.push_str(t);
                    }
                    _ => spans.push((1, t.to_string())),
                }
                word = !space;
            }
        }
        Ok(Layout {
            glyphs,
            pos: Some(pos),
            spans: Some(spans),
        })
    }

    /// Where a line may break inside `text` without splitting a cluster
    /// (a letter and its marks): `true` per char, before it.
    pub fn break_points(&self, text: &str) -> Result<Vec<bool>> {
        let chars: Vec<usize> = text.char_indices().map(|(i, _)| i).collect();
        let mut ok = vec![false; chars.len()];
        for run in runs(text) {
            let buffer = self.shape_run(text, &run)?;
            for g in buffer.glyph_infos() {
                if let Ok(i) = chars.binary_search(&(g.cluster as usize)) {
                    ok[i] = true;
                }
            }
        }
        Ok(ok)
    }

    /// fontkit's `font.layout(text, features).glyphs`, as glyph ids.
    fn layout_simple(&self, text: &str) -> Result<Vec<u16>> {
        // glyphsForString: one glyph per code point; a variation selector
        // goes with the code point before it
        let chars: Vec<(usize, u32)> = text.char_indices().map(|(i, c)| (i, c as u32)).collect();
        let mut base: Vec<(u16, Vec<u32>)> = Vec::with_capacity(chars.len());
        // the base glyph of each char, if any
        let mut base_of: Vec<Option<usize>> = Vec::with_capacity(chars.len());
        for (i, &(_, c)) in chars.iter().enumerate() {
            let next_vs = chars.get(i + 1).is_some_and(|n| is_variation_selector(n.1));
            if is_variation_selector(c) {
                base_of.push(None);
                continue;
            }
            let (gid, cps) = if next_vs {
                let vs = chars[i + 1].1;
                let gid = match self.file.font.charmap().map_unicode_variant(c, vs) {
                    Some(g) => g.to_u32() as u16,
                    None => self.file.glyph(c),
                };
                (gid, vec![c, vs])
            } else {
                (self.file.glyph(c), vec![c])
            };
            let gid = self.get_glyph(gid, cps);
            let cps = self.state().code_points[&gid].clone();
            base_of.push(Some(base.len()));
            base.push((gid, cps));
        }

        let mut glyphs: Vec<u16> = if !self.file.gsub || chars.is_empty() {
            base.iter().map(|b| b.0).collect()
        } else {
            let (out, rtl) = self.shape(text)?;
            let char_at = |byte: usize| chars.partition_point(|c| c.0 < byte);
            let mut starts: Vec<usize> = out.iter().map(|g| g.1).collect();
            starts.sort_unstable();
            starts.dedup();
            let space = self.file.glyph(0x20);
            let mut glyphs = Vec::with_capacity(out.len());
            let mut seen = std::collections::HashSet::new();
            for &(gid, cluster) in &out {
                // the first glyph of a cluster gets its text, like fontkit
                let first = seen.insert(cluster);
                let from = char_at(cluster);
                let to = starts
                    .get(starts.partition_point(|s| *s <= cluster))
                    .map_or(chars.len(), |s| char_at(*s));
                let mut bases: Vec<usize> = (from..to).filter_map(|i| base_of[i]).collect();
                bases.dedup();
                // a variation selector alone: fontkit has no glyph for it
                if bases.is_empty() || (from..to).all(|i| is_variation_selector(chars[i].1)) {
                    continue;
                }
                // harfrust composes a base and its marks (e + U+0301 = é);
                // fontkit keeps one glyph per character
                if first && bases.len() > 1 && self.composed(&chars[from..to]) == Some(gid) {
                    for b in &bases {
                        glyphs.push(base[*b].0);
                    }
                    continue;
                }
                // harfrust shows a default ignorable as a space; fontkit
                // does that later, by the glyph's own code points
                let gid = if to - from == 1 && gid == space && is_default_ignorable(chars[from].1) {
                    base[bases[0]].0
                } else {
                    gid
                };
                let cps = if first {
                    bases.iter().flat_map(|b| base[*b].1.iter().copied()).collect()
                } else {
                    Vec::new()
                };
                glyphs.push(self.get_glyph(gid, cps));
            }
            if rtl {
                glyphs.reverse();
            }
            glyphs
        };
        // hideDefaultIgnorables
        for g in glyphs.iter_mut() {
            if self.first_code_point(*g).is_some_and(is_default_ignorable) {
                let space = self.file.glyph(0x20);
                *g = self.get_glyph(space, vec![0x20]);
            }
        }
        Ok(glyphs)
    }

    /// pdf-lib's `widthOfTextAtSize`: the sum of the advance widths. For a
    /// complex script, HarfBuzz's advances (with kerning), as drawn.
    pub fn width_of_text(&self, text: &str, size: f64) -> Result<f64> {
        let layout = self.layout(text)?;
        let scale = self.file.scale();
        let mut total = 0.0;
        match &layout.pos {
            Some(pos) => {
                for p in pos {
                    total += p[0] as f64 * scale;
                }
            }
            None => {
                for g in layout.glyphs {
                    total += self.file.advance(g) * scale;
                }
            }
        }
        Ok(total * (size / 1000.0))
    }

    /// The id of glyph `g` in the file (the subset id of a subset font).
    fn file_id(&self, g: u16) -> u16 {
        if self.subset { self.state().remapper.remap(g) } else { g }
    }

    /// pdf-lib's `encodeText`: 4 hex digits per glyph.
    pub fn encode(&self, text: &str) -> Result<Vec<u8>> {
        let glyphs = self.layout(text)?.glyphs;
        let mut hex = Vec::with_capacity(glyphs.len() * 4);
        for g in glyphs {
            let id = self.file_id(g);
            hex.extend_from_slice(format!("{id:04X}").as_bytes());
        }
        Ok(hex)
    }

    /// The content stream operators that show `text` at font `size` (for
    /// drawText). Like pdf-lib (`<hex> Tj`), except for a complex script:
    /// - the glyphs are placed where HarfBuzz puts them (`TJ` moves and
    ///   `Ts` rise); pdf-lib draws them with their plain widths, so marks
    ///   sit in the wrong place;
    /// - the text is in `/ActualText` spans: the glyphs are not in text
    ///   order (eg. a vowel drawn before its consonant), marks are moved,
    ///   and one glyph can stand for more than one letter (Arabic letters
    ///   share a dotless form), so their ToUnicode alone does not give the
    ///   text back on copy.
    pub fn show_text(&self, text: &str, size: f64) -> Result<Vec<u8>> {
        use std::io::Write;
        let layout = self.layout(text)?;
        let mut out = Vec::new();
        let Some(pos) = &layout.pos else {
            out.push(b'<');
            for &g in &layout.glyphs {
                let id = self.file_id(g);
                let _ = write!(out, "{id:04X}");
            }
            out.extend_from_slice(b"> Tj");
            return Ok(out);
        };
        let mut rise = 0.0;
        // left to right: one span for the line. Right to left: one span per
        // cluster; viewers read spans in drawn order and turn the line around
        let spans = match &layout.spans {
            Some(spans) => spans.clone(),
            None => vec![(layout.glyphs.len(), text.to_string())],
        };
        let mut at = 0;
        for (n, span) in spans {
            out.extend_from_slice(b"/Span <</ActualText <FEFF");
            for u in span.encode_utf16() {
                let _ = write!(out, "{u:04X}");
            }
            out.extend_from_slice(b">>> BDC\n");
            let pad = layout.spans.is_some();
            self.place(
                &mut out,
                &layout.glyphs[at..at + n],
                &pos[at..at + n],
                size,
                &mut rise,
                pad,
            );
            out.extend_from_slice(b"\nEMC\n");
            at += n;
        }
        if rise != 0.0 {
            out.extend_from_slice(b"0 Ts\n");
        }
        out.pop();
        Ok(out)
    }

    /// `TJ` (and `Ts` for a rise) that put `glyphs` where `pos` says.
    ///
    /// With `pad`, a space glyph (it draws nothing) comes first at the start
    /// and last at the end. A viewer takes the place of an ActualText span
    /// from its first and last glyph; marks there (placed before or after
    /// the base) leave gaps or overlaps that it reads as spaces.
    fn place(&self, out: &mut Vec<u8>, glyphs: &[u16], pos: &[[i32; 3]], size: f64, rise: &mut f64, pad: bool) {
        use std::io::Write;
        let k = 1000.0 / self.file.upem;
        let dy = |i: usize| pos[i][2] as f64 * size / self.file.upem;
        // where each glyph starts, from the start of the span (1000 units)
        let mut pen = 0.0;
        let mut xs = Vec::with_capacity(glyphs.len());
        for p in pos {
            xs.push(pen + p[1] as f64 * k);
            pen += p[0] as f64 * k;
        }
        // (glyph, x, rise) in the order drawn
        let mut items: Vec<(u16, f64, f64)> = (0..glyphs.len()).map(|i| (glyphs[i], xs[i], dy(i))).collect();
        let space = self.file.glyph(0x20);
        if pad && space != 0 {
            let w = self.file.advance(space) * k;
            items.insert(0, (space, 0.0, 0.0));
            items.push((space, pen - w, 0.0));
        }
        let mut cur = 0.0;
        let mut open = false;
        let num = |out: &mut Vec<u8>, move_by: f64| {
            if move_by != 0.0 {
                crate::draw::write_num(out, -move_by);
                out.push(b' ');
            }
        };
        for (g, x, y) in items {
            if y != *rise {
                if open {
                    out.pop();
                    out.extend_from_slice(b"] TJ\n");
                    open = false;
                }
                *rise = y;
                crate::draw::write_num(out, *rise);
                out.extend_from_slice(b" Ts\n");
            }
            if !open {
                out.push(b'[');
                open = true;
            }
            num(out, x - cur);
            let id = self.file_id(g);
            let _ = write!(out, "<{id:04X}> ");
            cur = x + self.file.advance(g) * k;
        }
        if !open {
            out.push(b'[');
        }
        num(out, pen - cur);
        if out.last() == Some(&b' ') {
            out.pop();
        }
        out.extend_from_slice(b"] TJ");
    }

    /// The glyphs of the W array and the ToUnicode CMap, as
    /// `(id in the file, glyph id in the font, code points)`.
    fn used_glyphs(&self) -> Vec<(u16, u16, Vec<u32>)> {
        let st = self.state();
        if self.subset {
            // unlike pdf-lib, with `.notdef` (0): without a width in W, a
            // viewer draws it 1000 units wide
            return st
                .remapper
                .remapped_gids()
                .enumerate()
                .map(|(new, old)| (new as u16, old, st.code_points.get(&old).cloned().unwrap_or_default()))
                .collect();
        }
        // all glyphs of the character set, sorted by id. Unlike pdf-lib,
        // also the glyphs that layout made (ligatures, alternates): without
        // a width in W, a viewer draws them 1000 units wide.
        let mut cps = st.code_points.clone();
        for &c in &self.file.charset {
            cps.entry(self.file.glyph(c)).or_insert_with(|| vec![c]);
        }
        let mut ids: Vec<u16> = cps.keys().copied().collect();
        ids.sort_unstable();
        ids.dedup();
        ids.into_iter()
            .map(|g| (g, g, cps.get(&g).cloned().unwrap_or_default()))
            .collect()
    }

    /// Writes the font objects into `pdf` (the copy that save writes), the
    /// Type0 dict at `id`. Like `CustomFontEmbedder.embedFontDict`.
    pub fn write(&self, pdf: &mut lopdf::Document, id: ObjectId) -> Result<()> {
        let glyphs = self.used_glyphs();
        let file = &self.file;
        let scale = file.scale();
        let name = || Object::Name(self.base_name.as_bytes().to_vec());

        // the font file
        let (cid_type0, stream) = if self.subset {
            let sub = subsetter::subset(&file.data, 0, &self.state().remapper)
                .map_err(|e| Error::generic(format!("can not subset the font: {e}")))?;
            if file.cff {
                let font = FontRef::new(&sub).map_err(bad)?;
                let table = font
                    .table_data(Tag::new(b"CFF "))
                    .ok_or_else(|| Error::generic("the subset has no CFF table"))?;
                let mut dict = Dictionary::new();
                dict.set("Subtype", Object::Name(b"CIDFontType0C".to_vec()));
                (true, flate(dict, table.as_bytes())?)
            } else {
                (false, flate(Dictionary::new(), &sub)?)
            }
        } else {
            let packed = match file.packed.get() {
                Some(p) => p.clone(),
                None => file
                    .packed
                    .get_or_init(|| deflate(&file.data).unwrap_or_default())
                    .clone(),
            };
            let mut dict = Dictionary::new();
            if file.cff {
                // pdf-lib writes FontFile2 here; a CFF font must be FontFile3
                dict.set("Subtype", Object::Name(b"OpenType".to_vec()));
            }
            dict.set("Filter", Object::Name(b"FlateDecode".to_vec()));
            (file.cff, Stream::new(dict, packed))
        };
        let stream = pdf.add_object(Object::Stream(stream));

        let mut desc = Dictionary::new();
        desc.set("Type", Object::Name(b"FontDescriptor".to_vec()));
        desc.set("FontName", name());
        desc.set("Flags", Object::Integer(file.flags));
        desc.set(
            "FontBBox",
            Object::Array(file.bbox.iter().map(|v| num(v * scale)).collect()),
        );
        desc.set("ItalicAngle", num(file.italic_angle));
        desc.set("Ascent", num(file.ascent * scale));
        desc.set("Descent", num(file.descent * scale));
        let cap = if file.cap_height != 0.0 {
            file.cap_height
        } else {
            file.ascent
        };
        desc.set("CapHeight", num(cap * scale));
        desc.set("XHeight", num(file.x_height * scale));
        desc.set("StemV", Object::Integer(0));
        desc.set(
            if cid_type0 { "FontFile3" } else { "FontFile2" },
            Object::Reference(stream),
        );
        let desc = pdf.add_object(Object::Dictionary(desc));

        // W: runs of consecutive ids, like pdf-lib's `computeWidths`
        let mut widths: Vec<Object> = Vec::new();
        let mut section: Vec<Object> = Vec::new();
        for (i, (cid, gid, _)) in glyphs.iter().enumerate() {
            if i == 0 {
                widths.push(Object::Integer(*cid as i64));
            } else if *cid as i64 - glyphs[i - 1].0 as i64 != 1 {
                widths.push(Object::Array(std::mem::take(&mut section)));
                widths.push(Object::Integer(*cid as i64));
            }
            section.push(num(file.advance(*gid) * scale));
        }
        widths.push(Object::Array(section));

        let mut info = Dictionary::new();
        info.set("Registry", Object::String(b"Adobe".to_vec(), StringFormat::Literal));
        info.set("Ordering", Object::String(b"Identity".to_vec(), StringFormat::Literal));
        info.set("Supplement", Object::Integer(0));
        let mut cid = Dictionary::new();
        cid.set("Type", Object::Name(b"Font".to_vec()));
        let subtype: &[u8] = if cid_type0 { b"CIDFontType0" } else { b"CIDFontType2" };
        cid.set("Subtype", Object::Name(subtype.to_vec()));
        cid.set("CIDToGIDMap", Object::Name(b"Identity".to_vec()));
        cid.set("BaseFont", name());
        cid.set("CIDSystemInfo", Object::Dictionary(info));
        cid.set("FontDescriptor", Object::Reference(desc));
        cid.set("W", Object::Array(widths));
        let cid = pdf.add_object(Object::Dictionary(cid));

        // like pdf-lib, the ToUnicode of a subset has no `.notdef`
        let mapped = if self.subset { &glyphs[1..] } else { &glyphs[..] };
        let cmap = pdf.add_object(Object::Stream(flate(Dictionary::new(), &to_unicode(mapped))?));

        let mut font = Dictionary::new();
        font.set("Type", Object::Name(b"Font".to_vec()));
        font.set("Subtype", Object::Name(b"Type0".to_vec()));
        font.set("BaseFont", name());
        font.set("Encoding", Object::Name(b"Identity-H".to_vec()));
        font.set("DescendantFonts", Object::Array(vec![Object::Reference(cid)]));
        font.set("ToUnicode", Object::Reference(cmap));
        pdf.objects.insert(id, Object::Dictionary(font));
        Ok(())
    }
}

fn flate(mut dict: Dictionary, data: &[u8]) -> Result<Stream> {
    dict.set("Filter", Object::Name(b"FlateDecode".to_vec()));
    Ok(Stream::new(dict, deflate(data)?))
}

/// pdf-lib's `createCmap`.
fn to_unicode(glyphs: &[(u16, u16, Vec<u32>)]) -> Vec<u8> {
    use std::fmt::Write;
    let mut s = String::from(
        "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo <<\n  /Registry (Adobe)\n  \
         /Ordering (UCS)\n  /Supplement 0\n>> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n\
         1 begincodespacerange\n<0000><ffff>\nendcodespacerange\n",
    );
    let _ = writeln!(s, "{} beginbfchar", glyphs.len());
    for (i, (cid, _, cps)) in glyphs.iter().enumerate() {
        if i > 0 {
            s.push('\n');
        }
        let _ = write!(s, "<{cid:04X}> <");
        for &c in cps {
            if c < 0x10000 {
                let _ = write!(s, "{c:04X}");
            } else {
                let v = c - 0x10000;
                let _ = write!(s, "{:04X}{:04X}", 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF));
            }
        }
        s.push('>');
    }
    s.push_str("\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend");
    s.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::{create, load, save};

    // small OFL subsets of Noto Sans (TrueType) and Noto Sans JP (CFF)
    pub const TTF: &[u8] = include_bytes!("../../test/fixtures/fonts/noto-sans-test.ttf");
    pub const OTF: &[u8] = include_bytes!("../../test/fixtures/fonts/noto-sans-jp-test.otf");

    fn font(data: &[u8], subset: bool) -> CustomFont {
        let file = Arc::new(FontFile::parse(data.to_vec()).unwrap());
        CustomFont::new(file, subset, "Test".into(), vec![])
    }

    /// The values of pdf-lib 1.17.1 + @pdf-lib/fontkit 1.1.1, in this order
    /// (the order matters: fontkit keeps the code points of a glyph's first
    /// use, so U+200D gets the `.notdef` of U+0301 and is not hidden).
    type Case<'a> = (&'a [u8], &'a str, [f64; 3], [(&'a str, f64, &'a str); 5]);

    #[test]
    fn layout_and_metrics_match_fontkit() {
        let cases: [Case; 2] = [
            (
                TTF,
                "NotoSans-Regular",
                [13.620000000000001, 10.69, 7.342143906020558],
                [
                    ("office fi", 41.484, "005000DF00440046000100DD"),
                    ("AVATAR", 44.34, "002200370022003500220033"),
                    ("e\u{301}", 13.968, "00460000"),
                    ("日本語 ABC", 47.772, "0000000000000001002200230024"),
                    ("a\u{200d}b", 21.312, "004200000043"),
                ],
            ),
            (
                OTF,
                "NotoSansJP-Regular",
                [14.48, 11.6, 6.906077348066298],
                [
                    ("office fi", 40.944, "005001040044004600010102"),
                    ("AVATAR", 43.596000000000004, "002200370022003500220033"),
                    ("e\u{301}", 18.648, "00460000"),
                    ("日本語 ABC", 61.524, "00FC00FD00FF0001002200230024"),
                    ("a\u{200d}b", 26.172, "004200000043"),
                ],
            ),
        ];
        for (data, name, [h, h_no_desc, size], texts) in cases {
            let f = font(data, false);
            assert_eq!(f.file.name, name);
            let [top, bottom, desc] = f.file.vertical();
            assert_eq!(((top - bottom) / 1000.0) * 10.0, h);
            assert_eq!(((top - bottom + desc) / 1000.0) * 10.0, h_no_desc);
            assert_eq!((1000.0 * 10.0) / (top - bottom), size);
            for (text, width, hex) in texts {
                assert_eq!(f.width_of_text(text, 12.0).unwrap(), width, "{name} {text}");
                assert_eq!(
                    String::from_utf8(f.encode(text).unwrap()).unwrap(),
                    hex,
                    "{name} {text}"
                );
            }
        }
        let f = font(TTF, false);
        let cs = f.file.code_points();
        assert_eq!((cs.len(), cs[0], cs[cs.len() - 1]), (207, 32, 65535));
        let f = font(OTF, false);
        let cs = f.file.code_points();
        assert_eq!((cs.len(), cs[0], cs[cs.len() - 1]), (121, 32, 134071));
    }

    #[test]
    fn features_turn_ligatures_off() {
        let file = Arc::new(FontFile::parse(TTF.to_vec()).unwrap());
        let f = CustomFont::new(file, false, "Test".into(), parse_features(b"liga\x00"));
        // f, f, i: no ligature
        assert_eq!(f.layout("ffi").unwrap().glyphs.len(), 3);
        assert_eq!(font(TTF, false).layout("ffi").unwrap().glyphs.len(), 1);
    }

    #[test]
    fn subset_ids_count_from_one_in_order_of_use() {
        let f = font(TTF, true);
        assert_eq!(f.encode("ba").unwrap(), b"00010002");
        assert_eq!(f.encode("abc").unwrap(), b"000200010003");
    }

    fn saved_font(data: &[u8], subset: bool) -> (lopdf::Document, ObjectId) {
        let mut d = create(false, b"");
        let f = font(data, subset);
        f.encode("office 日本").unwrap();
        let id = d.pdf.add_object(Object::Null);
        d.fonts.insert(id, crate::font::Embedded::Custom(Box::new(f)));
        let doc = load(&save(&mut d, 0).unwrap(), 0, b"").unwrap();
        (doc.pdf, id)
    }

    #[test]
    fn writes_type0_fonts_like_pdf_lib() {
        for (data, subset, cid_type, file_key) in [
            (TTF, false, &b"CIDFontType2"[..], &b"FontFile2"[..]),
            (TTF, true, b"CIDFontType2", b"FontFile2"),
            (OTF, false, b"CIDFontType0", b"FontFile3"),
            (OTF, true, b"CIDFontType0", b"FontFile3"),
        ] {
            let (pdf, id) = saved_font(data, subset);
            let font = pdf.get_dictionary(id).unwrap();
            assert_eq!(font.get(b"Subtype").unwrap().as_name().unwrap(), b"Type0");
            assert_eq!(font.get(b"Encoding").unwrap().as_name().unwrap(), b"Identity-H");
            let kids = font.get(b"DescendantFonts").unwrap().as_array().unwrap();
            let cid = pdf.get_dictionary(kids[0].as_reference().unwrap()).unwrap();
            assert_eq!(cid.get(b"Subtype").unwrap().as_name().unwrap(), cid_type);
            let desc = pdf
                .get_dictionary(cid.get(b"FontDescriptor").unwrap().as_reference().unwrap())
                .unwrap();
            assert_eq!(desc.get(b"Flags").unwrap().as_i64().unwrap(), 4);
            let stream = pdf
                .get_object(desc.get(file_key).unwrap().as_reference().unwrap())
                .unwrap()
                .as_stream()
                .unwrap();
            let bytes = stream.decompressed_content().unwrap();
            if subset {
                // the subset is much smaller and still a font
                assert!(bytes.len() < data.len() / 2);
                if data == OTF {
                    assert_eq!(
                        stream.dict.get(b"Subtype").unwrap().as_name().unwrap(),
                        b"CIDFontType0C"
                    );
                } else {
                    FontRef::new(&bytes).unwrap();
                }
            } else {
                assert_eq!(bytes, data);
            }
            let cmap = pdf
                .get_object(font.get(b"ToUnicode").unwrap().as_reference().unwrap())
                .unwrap()
                .as_stream()
                .unwrap()
                .decompressed_content()
                .unwrap();
            let cmap = String::from_utf8(cmap).unwrap();
            if subset {
                // o, ffi, c, e, space, 日, 本 (only the CJK font has them, and
                // `.notdef` is not mapped); the ligature has all 3 letters
                let n = if data == OTF { 7 } else { 5 };
                assert!(cmap.contains(&format!("{n} beginbfchar\n<0001> <006F>\n<0002> <006600660069>\n")));
            } else {
                assert!(cmap.contains("<0050> <006F>"));
            }
        }
    }

    #[test]
    fn full_font_widths_have_the_glyphs_of_layout() {
        // the ffi ligature is not in the cmap; pdf-lib leaves it out of W
        let (pdf, id) = saved_font(TTF, false);
        let font = pdf.get_dictionary(id).unwrap();
        let kids = font.get(b"DescendantFonts").unwrap().as_array().unwrap();
        let cid = pdf.get_dictionary(kids[0].as_reference().unwrap()).unwrap();
        let w = cid.get(b"W").unwrap().as_array().unwrap();
        let has = |gid: i64| {
            w.chunks(2).any(|c| {
                let start = c[0].as_i64().unwrap();
                (start..start + c[1].as_array().unwrap().len() as i64).contains(&gid)
            })
        };
        assert!(has(0xDF));
        assert!(has(0));
    }

    #[test]
    fn thai_is_laid_out_like_harfbuzz_and_copies_right() {
        // values of hb-shape (HarfBuzz) with this font
        const THAI: &[u8] = include_bytes!("../../test/fixtures/fonts/noto-sans-thai.ttf");
        let f = font(THAI, true);
        let l = f.layout("น้ำ").unwrap();
        // nikhahit (59) moves before the tone mark; sara aa (86) stays last
        assert_eq!(l.glyphs[0], 71);
        assert_eq!(l.glyphs.len(), 4);
        assert_eq!(*l.glyphs.last().unwrap(), 86);
        assert!(l.pos.is_some());
        assert_eq!(f.width_of_text("น้ำ", 1000.0).unwrap(), 1019.0);
        // a line never breaks before a mark or sara am
        assert_eq!(f.break_points("น้ำใจ").unwrap(), [true, false, false, true, true]);
        // the text is in an ActualText span; the glyphs are placed with TJ
        let ops = String::from_utf8(f.show_text("น้ำ", 20.0).unwrap()).unwrap();
        assert!(
            ops.starts_with("/Span <</ActualText <FEFF0E190E490E33>>> BDC\n["),
            "{ops}"
        );
        assert!(ops.ends_with("] TJ\nEMC") || ops.ends_with("0 Ts"), "{ops}");
        // Latin text in the same font is still drawn like pdf-lib
        assert_eq!(f.show_text("", 20.0).unwrap(), b"<> Tj");
    }

    #[test]
    fn bidi_runs_in_drawn_order() {
        let r = |t: &str| -> Vec<(String, bool)> {
            runs(t)
                .into_iter()
                .map(|r| (t[r.start..r.end].to_string(), r.rtl))
                .collect()
        };
        let s = |t: &str, rtl: bool| (t.to_string(), rtl);
        // numbers in Arabic run left to right, on the left of the word
        assert_eq!(r("مرحبا 123"), [s("123", false), s("مرحبا ", true)]);
        assert_eq!(r("السعر: 1,250.50"), [s("1,250.50", false), s("السعر: ", true)]);
        // Arabic in an English line
        assert_eq!(
            r("Hello مرحبا world"),
            [s("Hello ", false), s("مرحبا", true), s(" world", false)]
        );
        // after an Arabic letter the digits are Arabic numbers (rule W2),
        // so the date parts go right to left, as in browsers
        assert_eq!(
            r("Order 66 وصل 2024-05-01"),
            [
                s("Order 66 ", false),
                s("01", false),
                s("-", true),
                s("05", false),
                s("-", true),
                s("2024", false),
                s("وصل ", true)
            ]
        );
        // a digit run takes the script of the text before it
        let rs = runs("مرحبا 123");
        assert_eq!(rs[0].script, Script::ARABIC);
    }

    /// `TTF` with its cmap replaced by `cmap`.
    fn with_cmap(cmap: &[u8]) -> Vec<u8> {
        let mut data = TTF.to_vec();
        let tables = u16::from_be_bytes([data[4], data[5]]) as usize;
        let offset = data.len() as u32;
        for i in 0..tables {
            let rec = 12 + i * 16;
            if &data[rec..rec + 4] == b"cmap" {
                data[rec + 8..rec + 12].copy_from_slice(&offset.to_be_bytes());
                data[rec + 12..rec + 16].copy_from_slice(&(cmap.len() as u32).to_be_bytes());
            }
        }
        data.extend_from_slice(cmap);
        data
    }

    #[test]
    fn a_cmap_with_overlapping_ranges_is_an_error() {
        // format 12 with 64 groups, each of all of Unicode: 70 million code
        // points without the limit
        let groups = 64u32;
        let mut t = Vec::new();
        for v in [0u16, 1, 3, 10] {
            t.extend_from_slice(&v.to_be_bytes());
        }
        t.extend_from_slice(&12u32.to_be_bytes()); // subtable offset
        t.extend_from_slice(&12u16.to_be_bytes());
        t.extend_from_slice(&0u16.to_be_bytes());
        t.extend_from_slice(&(16 + groups * 12).to_be_bytes());
        t.extend_from_slice(&0u32.to_be_bytes());
        t.extend_from_slice(&groups.to_be_bytes());
        for _ in 0..groups {
            for v in [0u32, 0x10FFFF, 1] {
                t.extend_from_slice(&v.to_be_bytes());
            }
        }
        let e = FontFile::parse(with_cmap(&t)).err().unwrap();
        assert_eq!(e.message, "can not read the font: the cmap is too big");
        // one group of all of Unicode is fine
        let one = t.len() - (groups as usize - 1) * 12;
        let mut t1 = t[..one].to_vec();
        t1[16..20].copy_from_slice(&28u32.to_be_bytes());
        t1[24..28].copy_from_slice(&1u32.to_be_bytes());
        assert_eq!(FontFile::parse(with_cmap(&t1)).unwrap().code_points().len(), 0x110000);
    }

    #[test]
    fn a_font_is_read_once_while_it_is_used() {
        let a = super::load(TTF).unwrap();
        // other memory, the same bytes
        let copy = TTF.to_vec();
        let b = super::load(&copy).unwrap();
        assert!(Arc::ptr_eq(&a, &b));
        // other bytes with the same start, end and length: another font
        let mut other = TTF.to_vec();
        other[TTF.len() / 2] ^= 1;
        let c = super::load(&other).unwrap();
        assert!(!Arc::ptr_eq(&a, &c));
        drop(c);
        drop((a, b));
        // freed with its last user
        assert!(
            LOADED
                .lock()
                .unwrap()
                .iter()
                .filter(|(k, _)| *k == font_key(TTF))
                .all(|(_, w)| w.strong_count() == 0)
        );
    }

    #[test]
    fn broken_fonts_are_errors() {
        assert!(FontFile::parse(b"not a font".to_vec()).is_err());
        assert!(FontFile::parse(TTF[..100].to_vec()).is_err());
    }
}
