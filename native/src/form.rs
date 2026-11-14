//! Interactive forms (AcroForm), like pdf-lib's `PDFForm`, its field
//! classes, `core/acroform` and the default appearance providers
//! (`appearances.ts`, `text/layout.ts`, the form parts of `operations.ts`).
//!
//! Each Dart form call is one FFI call (`dox_pdf_form`) with an op code.
//! Strings go in and out as a list: u32 length (little endian) + UTF-8.
//!
//! Broken parts of a loaded file (a kid that is not a dict, a widget with
//! no page, a missing appearance) are skipped, never a crash.

use std::collections::{HashMap, HashSet};
use std::f64::consts::PI;
use std::ffi::c_void;

use lopdf::{Dictionary, Document, Object, ObjectId, Stream, StringFormat};

use crate::document::{as_f64, deref, num, page_entries, ref_from_i64, ref_to_i64};
use crate::draw::{self, write_num};
use crate::ffi_util::*;
use crate::font;
use crate::metadata::{decode_text, text_object};

/// Most links followed in a walk over fields (`/Parent`, `/Kids`).
const MAX_DEPTH: usize = 256;

/// Form state of a document. Part of `Doc`, so it is cloned with it.
#[derive(Clone, Default)]
pub struct FormState {
    /// `getForm` was called. Only then `save` updates appearances, like
    /// pdf-lib's `formCache.getValue()`.
    accessed: bool,
    /// pdf-lib's `dirtyFields`.
    dirty: HashSet<ObjectId>,
    /// pdf-lib's `getDefaultFont`: Helvetica, embedded on first use.
    default_font: Option<ObjectId>,
}

// ------------------------------------------------------------ the font

/// What appearances need from a font. The standard fonts have it now. A
/// custom font (font.rs) adds an `impl` and a branch in `form_font`; the
/// form code does not change.
pub trait FormFont {
    /// The font name as pdf-lib's `PDFFont.name`: the `/DA` and resource name.
    fn name(&self) -> &str;
    /// `widthOfTextAtSize`.
    fn width(&self, text: &str, size: f64) -> Result<f64>;
    /// `encodeText`: the hex digits of the text, without `<>`.
    fn encode(&self, text: &str) -> Result<Vec<u8>>;
    /// `heightAtSize(size, { descender })`.
    fn height(&self, size: f64, descender: bool) -> f64;
    /// The operators that show the text at `size`: `<hex> Tj` like pdf-lib.
    /// A custom font places the glyphs of a complex script (see
    /// `CustomFont::show_text`).
    fn show(&self, text: &str, _size: f64) -> Result<Vec<u8>> {
        let mut out = vec![b'<'];
        out.extend(self.encode(text)?);
        out.extend_from_slice(b"> Tj");
        Ok(out)
    }
}

impl FormFont for font::Font {
    fn name(&self) -> &str {
        &self.name
    }
    fn width(&self, text: &str, size: f64) -> Result<f64> {
        self.width_of_text(text, size)
    }
    fn encode(&self, text: &str) -> Result<Vec<u8>> {
        let mut hex = Vec::with_capacity(text.len() * 2);
        for (code, _) in self.glyphs(text)? {
            hex.extend_from_slice(format!("{code:02X}").as_bytes());
        }
        Ok(hex)
    }
    fn height(&self, size: f64, descender: bool) -> f64 {
        let [top, bottom, desc] = self.vertical();
        let mut h = top - bottom;
        if !descender {
            h += desc;
        }
        (h / 1000.0) * size
    }
}

/// An embedded font: its ref and its metrics.
struct FieldFont {
    id: ObjectId,
    f: Box<dyn FormFont>,
}

fn form_font(doc: &Doc, id: ObjectId) -> Result<FieldFont> {
    let f: Box<dyn FormFont> = match doc.fonts.get(&id) {
        Some(font::Embedded::Standard(std_id)) => Box::new(StdFont(font::font(*std_id)?)),
        // shares the glyphs with the document's font, so a subset gets them
        Some(font::Embedded::Custom(c)) => Box::new(c.share()),
        None => return Err(Error::generic("the font is not embedded in this document")),
    };
    Ok(FieldFont { id, f })
}

impl FormFont for crate::custom_font::CustomFont {
    fn name(&self) -> &str {
        &self.file.name
    }
    fn width(&self, text: &str, size: f64) -> Result<f64> {
        self.width_of_text(text, size)
    }
    fn encode(&self, text: &str) -> Result<Vec<u8>> {
        crate::custom_font::CustomFont::encode(self, text)
    }
    fn height(&self, size: f64, descender: bool) -> f64 {
        let [top, bottom, desc] = self.file.vertical();
        let mut h = top - bottom;
        if !descender {
            h += desc;
        }
        (h / 1000.0) * size
    }
    fn show(&self, text: &str, size: f64) -> Result<Vec<u8>> {
        self.show_text(text, size)
    }
}

/// A `'static` standard font as a boxed `FormFont`.
struct StdFont(&'static font::Font);

impl FormFont for StdFont {
    fn name(&self) -> &str {
        self.0.name()
    }
    fn width(&self, text: &str, size: f64) -> Result<f64> {
        self.0.width(text, size)
    }
    fn encode(&self, text: &str) -> Result<Vec<u8>> {
        self.0.encode(text)
    }
    fn height(&self, size: f64, descender: bool) -> f64 {
        FormFont::height(self.0, size, descender)
    }
}

/// pdf-lib's `getDefaultFont`: Helvetica, embedded once per document.
fn default_font(doc: &mut Doc) -> Result<ObjectId> {
    if let Some(id) = doc.form.default_font
        && doc.fonts.contains_key(&id)
    {
        return Ok(id);
    }
    const HELVETICA: i32 = 4;
    let id = font::embed(&mut doc.pdf, HELVETICA, None)?;
    doc.fonts.insert(id, font::Embedded::Standard(HELVETICA));
    doc.form.default_font = Some(id);
    Ok(id)
}

// ------------------------------------------------------------ objects

/// Field kinds. The same numbers are in form_bindings.dart.
pub const BUTTON: i32 = 0;
pub const CHECK_BOX: i32 = 1;
pub const DROPDOWN: i32 = 2;
pub const OPTION_LIST: i32 = 3;
pub const RADIO_GROUP: i32 = 4;
pub const SIGNATURE: i32 = 5;
pub const TEXT_FIELD: i32 = 6;

// field flags (pdf-lib's `flags.ts`)
const RADIO: i64 = 1 << 15;
const PUSH_BUTTON: i64 = 1 << 16;
const MULTILINE: i64 = 1 << 12;
const PASSWORD: i64 = 1 << 13;
const FILE_SELECT: i64 = 1 << 20;
const COMB: i64 = 1 << 24;
const RICH_TEXT: i64 = 1 << 25;
const COMBO: i64 = 1 << 17;
const EDIT: i64 = 1 << 18;
const SORT: i64 = 1 << 19;
const MULTI_SELECT: i64 = 1 << 21;

fn name(n: &str) -> Object {
    Object::Name(n.as_bytes().to_vec())
}

fn dict_of(pdf: &Document, id: ObjectId) -> Option<&Dictionary> {
    match pdf.objects.get(&id) {
        Some(Object::Dictionary(d)) => Some(d),
        _ => None,
    }
}

fn dict_mut(pdf: &mut Document, id: ObjectId) -> Result<&mut Dictionary> {
    match pdf.objects.get_mut(&id) {
        Some(Object::Dictionary(d)) => Ok(d),
        _ => Err(Error::generic(format!("object {} {} R is not a dict", id.0, id.1))),
    }
}

/// `dict.lookup(key)`: the value, with references followed.
fn get<'a>(pdf: &'a Document, d: &'a Dictionary, key: &[u8]) -> Option<&'a Object> {
    deref(pdf, d.get(key).ok()?)
}

fn get_dict<'a>(pdf: &'a Document, d: &'a Dictionary, key: &[u8]) -> Option<&'a Dictionary> {
    match get(pdf, d, key)? {
        Object::Dictionary(d) => Some(d),
        _ => None,
    }
}

fn get_num(pdf: &Document, d: &Dictionary, key: &[u8]) -> Option<f64> {
    get(pdf, d, key).and_then(as_f64)
}

/// The text of a string object (`decodeText`), or `None`.
fn text_of(obj: &Object) -> Option<String> {
    match obj {
        Object::String(bytes, _) => Some(decode_text(bytes)),
        _ => None,
    }
}

/// A name as pdf-lib's `PDFName.decodeText`: each byte is one char.
fn name_text(n: &[u8]) -> String {
    n.iter().map(|&b| b as char).collect()
}

/// `dict[key]`, a direct array or a reference to one, for changes. Made
/// (empty, direct) when `create` and it is missing or broken.
fn array_mut<'a>(pdf: &'a mut Document, holder: ObjectId, key: &[u8], create: bool) -> Option<&'a mut Vec<Object>> {
    let target = match dict_of(pdf, holder)?.get(key) {
        Ok(Object::Reference(id)) if matches!(pdf.objects.get(id), Some(Object::Array(_))) => Some(*id),
        Ok(Object::Array(_)) => None,
        _ if create => {
            dict_mut(pdf, holder).ok()?.set(key, Object::Array(vec![]));
            None
        }
        _ => return None,
    };
    match target {
        Some(id) => match pdf.objects.get_mut(&id) {
            Some(Object::Array(a)) => Some(a),
            _ => None,
        },
        None => match dict_mut(pdf, holder).ok()?.get_mut(key) {
            Ok(Object::Array(a)) => Some(a),
            _ => None,
        },
    }
}

/// The refs in an array that point at dicts (pdf-lib's
/// `createPDFAcroFields`: anything else is skipped).
fn dict_refs(pdf: &Document, list: Option<&Object>) -> Vec<ObjectId> {
    match list.and_then(|l| deref(pdf, l)) {
        Some(Object::Array(items)) => items
            .iter()
            .filter_map(|o| match o {
                Object::Reference(id) if dict_of(pdf, *id).is_some() => Some(*id),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// `dict[key]` as a sub dict for changes: a direct dict or a reference to
/// one. Made (direct) when it is missing.
fn sub_dict_mut<'a>(pdf: &'a mut Document, holder: ObjectId, key: &[u8]) -> Result<&'a mut Dictionary> {
    let target = match dict_of(pdf, holder).and_then(|d| d.get(key).ok()) {
        Some(Object::Reference(id)) if dict_of(pdf, *id).is_some() => Some(*id),
        Some(Object::Dictionary(_)) => None,
        _ => {
            dict_mut(pdf, holder)?.set(key, Object::Dictionary(Dictionary::new()));
            None
        }
    };
    match target {
        Some(id) => dict_mut(pdf, id),
        None => Ok(dict_mut(pdf, holder)?.get_mut(key)?.as_dict_mut()?),
    }
}

// ------------------------------------------------------------ the AcroForm

fn catalog_id(pdf: &Document) -> Result<ObjectId> {
    match pdf.trailer.get(b"Root") {
        Ok(Object::Reference(id)) if dict_of(pdf, *id).is_some() => Ok(*id),
        _ => Err(Error::generic("the document has no catalog")),
    }
}

/// The AcroForm dict (an indirect object). `create` makes it like
/// pdf-lib's `getOrCreateAcroForm`; a direct dict in the catalog moves
/// into its own object, so it can be changed in one place.
fn acroform(pdf: &mut Document, create: bool) -> Result<Option<ObjectId>> {
    let catalog = catalog_id(pdf)?;
    let current = dict_of(pdf, catalog).and_then(|c| c.get(b"AcroForm").ok()).cloned();
    let id = match current {
        Some(Object::Reference(id)) if dict_of(pdf, id).is_some() => id,
        Some(Object::Dictionary(d)) => pdf.add_object(Object::Dictionary(d)),
        _ if create => {
            let mut d = Dictionary::new();
            d.set("Fields", Object::Array(vec![]));
            pdf.add_object(Object::Dictionary(d))
        }
        _ => return Ok(None),
    };
    dict_mut(pdf, catalog)?.set("AcroForm", Object::Reference(id));
    Ok(Some(id))
}

fn acroform_ref(pdf: &Document) -> Option<ObjectId> {
    let catalog = dict_of(pdf, catalog_id(pdf).ok()?)?;
    match catalog.get(b"AcroForm").ok()? {
        Object::Reference(id) if dict_of(pdf, *id).is_some() => Some(*id),
        _ => None,
    }
}

/// The top level fields (`/Fields`).
fn top_fields(pdf: &Document) -> Vec<ObjectId> {
    let Some(form) = acroform_ref(pdf).and_then(|id| dict_of(pdf, id)) else {
        return Vec::new();
    };
    dict_refs(pdf, form.get(b"Fields").ok())
}

// ------------------------------------------------------------ fields

fn kids(pdf: &Document, id: ObjectId) -> Vec<ObjectId> {
    dict_of(pdf, id)
        .map(|d| dict_refs(pdf, d.get(b"Kids").ok()))
        .unwrap_or_default()
}

/// pdf-lib's `isNonTerminalAcroField`: a kid is a dict with a `/T`.
fn is_non_terminal(pdf: &Document, id: ObjectId) -> bool {
    let Some(Object::Array(items)) = dict_of(pdf, id).and_then(|d| get(pdf, d, b"Kids")) else {
        return false;
    };
    items
        .iter()
        .any(|k| matches!(deref(pdf, k), Some(Object::Dictionary(d)) if d.has(b"T")))
}

/// The parent field: `/Parent` must be a reference to a dict, like
/// pdf-lib's `getParent`.
fn parent(pdf: &Document, id: ObjectId) -> Option<ObjectId> {
    match dict_of(pdf, id)?.get(b"Parent").ok()? {
        Object::Reference(p) if dict_of(pdf, *p).is_some() => Some(*p),
        _ => None,
    }
}

/// The field and its parents, up to the root (with a limit).
fn chain(pdf: &Document, id: ObjectId) -> Vec<ObjectId> {
    let mut out = vec![id];
    let mut seen = HashSet::from([id]);
    while out.len() < MAX_DEPTH {
        match parent(pdf, *out.last().unwrap()) {
            Some(p) if seen.insert(p) => out.push(p),
            _ => break,
        }
    }
    out
}

/// pdf-lib's `getInheritableAttribute`: the value of the nearest field
/// in the chain that has it, references followed.
fn inherited<'a>(pdf: &'a Document, id: ObjectId, key: &[u8]) -> Option<&'a Object> {
    chain(pdf, id)
        .into_iter()
        .find_map(|f| dict_of(pdf, f).and_then(|d| d.get(key).ok()))
        .and_then(|o| deref(pdf, o))
}

fn flags(pdf: &Document, id: ObjectId) -> i64 {
    inherited(pdf, id, b"Ff")
        .and_then(as_f64)
        .map(|v| v as i64)
        .unwrap_or(0)
}

fn has_flag(pdf: &Document, id: ObjectId, flag: i64) -> bool {
    flags(pdf, id) & flag != 0
}

fn set_flag(pdf: &mut Document, id: ObjectId, flag: i64, on: bool) -> Result<()> {
    let f = flags(pdf, id);
    let f = if on { f | flag } else { f & !flag };
    dict_mut(pdf, id)?.set("Ff", Object::Integer(f));
    Ok(())
}

/// The kind of a terminal field, or `None` (non-terminal, or a type that
/// pdf-lib's `convertToPDFField` skips).
fn kind(pdf: &Document, id: ObjectId) -> Option<i32> {
    if is_non_terminal(pdf, id) {
        return None;
    }
    let Object::Name(ft) = inherited(pdf, id, b"FT")? else {
        return None;
    };
    let f = flags(pdf, id);
    Some(match ft.as_slice() {
        b"Btn" if f & PUSH_BUTTON != 0 => BUTTON,
        b"Btn" if f & RADIO != 0 => RADIO_GROUP,
        b"Btn" => CHECK_BOX,
        b"Ch" if f & COMBO != 0 => DROPDOWN,
        b"Ch" => OPTION_LIST,
        b"Tx" => TEXT_FIELD,
        b"Sig" => SIGNATURE,
        _ => return None,
    })
}

/// pdf-lib's `getAllFields` + `convertToPDFField`: every terminal field in
/// tree order. A field seen twice (a loop) is skipped.
fn all_fields(pdf: &Document) -> Vec<(ObjectId, i32)> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    // explicit stack of (fields, next index), so a deep tree can not
    // overflow the Rust stack
    let mut stack: Vec<(Vec<ObjectId>, usize)> = vec![(top_fields(pdf), 0)];
    while let Some((list, idx)) = stack.pop() {
        let Some(&id) = list.get(idx) else { continue };
        stack.push((list, idx + 1));
        if !seen.insert(id) {
            continue;
        }
        if is_non_terminal(pdf, id) {
            if stack.len() < MAX_DEPTH {
                stack.push((kids(pdf, id), 0));
            }
        } else if let Some(k) = kind(pdf, id) {
            out.push((id, k));
        }
    }
    out
}

fn partial_name(pdf: &Document, id: ObjectId) -> Option<String> {
    dict_of(pdf, id).and_then(|d| get(pdf, d, b"T")).and_then(text_of)
}

/// pdf-lib's `getFullyQualifiedName() ?? ''`. A part without `/T` is
/// "undefined", as in pdf-lib.
fn full_name(pdf: &Document, id: ObjectId) -> String {
    let parts = chain(pdf, id);
    let mut name: Option<String> = partial_name(pdf, *parts.last().unwrap());
    for f in parts.iter().rev().skip(1) {
        name = Some(format!(
            "{}.{}",
            name.as_deref().unwrap_or("undefined"),
            partial_name(pdf, *f).as_deref().unwrap_or("undefined")
        ));
    }
    name.unwrap_or_default()
}

/// pdf-lib's `getWidgets`: the field itself when it has no `/Kids`, else
/// its kids that are dicts.
fn widgets(pdf: &Document, id: ObjectId) -> Vec<ObjectId> {
    match dict_of(pdf, id).and_then(|d| get(pdf, d, b"Kids")) {
        Some(Object::Array(_)) => kids(pdf, id),
        _ => vec![id],
    }
}

/// pdf-lib's `normalizedEntries().Kids` + push: a field that is its own
/// widget gets `Kids [itself]` first.
fn add_widget(pdf: &mut Document, field: ObjectId, widget: ObjectId) -> Result<()> {
    let own = !matches!(
        dict_of(pdf, field).and_then(|d| get(pdf, d, b"Kids")),
        Some(Object::Array(_))
    );
    if own {
        dict_mut(pdf, field)?.set("Kids", Object::Array(vec![Object::Reference(field)]));
    }
    array_mut(pdf, field, b"Kids", true)
        .ok_or_else(|| Error::generic("the field has no Kids"))?
        .push(Object::Reference(widget));
    Ok(())
}

/// The `/DA` text of a dict (pdf-lib's `getDefaultAppearance`).
fn own_da(pdf: &Document, id: ObjectId) -> Option<Vec<u8>> {
    match dict_of(pdf, id).and_then(|d| get(pdf, d, b"DA"))? {
        Object::String(b, StringFormat::Hexadecimal) => Some(decode_text(b).into_bytes()),
        Object::String(b, _) => Some(b.clone()),
        _ => None,
    }
}

/// The `/DA` of a field. pdf-lib reads only the field's own entry; we
/// also take it from a parent field or the AcroForm, as the PDF spec says.
fn field_da(pdf: &Document, id: ObjectId) -> Option<Vec<u8>> {
    chain(pdf, id)
        .into_iter()
        .chain(acroform_ref(pdf))
        .find_map(|f| own_da(pdf, f))
}

fn set_da(pdf: &mut Document, id: ObjectId, da: Vec<u8>) -> Result<()> {
    dict_mut(pdf, id)?.set("DA", Object::String(da, StringFormat::Literal));
    Ok(())
}

// ------------------------------------------------------------ /DA parsing

/// The tokens of a `/DA` text: runs of non-whitespace, as byte ranges.
/// One pass, so a long or hostile `/DA` costs linear time. The rules below
/// give the same result as pdf-lib's three `/DA` regexes on real files.
fn da_tokens(da: &[u8]) -> Vec<(usize, usize)> {
    let ws = |b: u8| matches!(b, 0 | b'\t' | b'\n' | 0x0c | b'\r' | b' ');
    let mut out = Vec::new();
    let mut i = 0;
    while i < da.len() {
        if ws(da[i]) {
            i += 1;
            continue;
        }
        let start = i;
        while i < da.len() && !ws(da[i]) {
            i += 1;
        }
        out.push((start, i));
    }
    out
}

/// `\d*\.\d+|\d+` over the whole token.
fn is_num(t: &[u8]) -> bool {
    let digits = |s: &[u8]| s.iter().all(u8::is_ascii_digit);
    match t.iter().position(|&b| b == b'.') {
        Some(dot) => digits(&t[..dot]) && t.len() > dot + 1 && digits(&t[dot + 1..]),
        None => !t.is_empty() && digits(t),
    }
}

/// `/name` in a token: the offset of the `/` (a name has 1 char or more).
fn name_at(t: &[u8]) -> Option<usize> {
    t.iter().position(|&b| b == b'/').filter(|&p| p + 1 < t.len())
}

/// The last `Tf`: (start of `/name`, end of `Tf`, name, size). Like the
/// regex `/(name)\s*(num)?\s+Tf`; with `need_size`, the size must be there.
fn last_tf(da: &[u8], need_size: bool) -> Option<(usize, usize, Vec<u8>, Option<f64>)> {
    let toks = da_tokens(da);
    let tok = |i: usize| &da[toks[i].0..toks[i].1];
    (1..toks.len()).rev().find_map(|i| {
        if !tok(i).starts_with(b"Tf") {
            return None;
        }
        let end = toks[i].0 + 2;
        if i >= 2
            && is_num(tok(i - 1))
            && let Some(n) = name_at(tok(i - 2))
        {
            let name = tok(i - 2)[n + 1..].to_vec();
            let size = std::str::from_utf8(tok(i - 1)).ok()?.parse().ok();
            return Some((toks[i - 2].0 + n, end, name, size));
        }
        if need_size {
            return None;
        }
        let n = name_at(tok(i - 1))?;
        Some((toks[i - 1].0 + n, end, tok(i - 1)[n + 1..].to_vec(), None))
    })
}

/// appearances.ts `getDefaultFontSize`.
fn da_font_size(da: Option<&[u8]>) -> Option<f64> {
    last_tf(da?, true)?.3.filter(|v| v.is_finite())
}

/// appearances.ts `getDefaultColor`: the last `g`, `rg` or `k` with numbers
/// before it (up to 4 are taken, like the regex).
fn da_color(da: Option<&[u8]>) -> Option<Color> {
    let da = da?;
    let toks = da_tokens(da);
    let tok = |i: usize| &da[toks[i].0..toks[i].1];
    let (i, op) = (1..toks.len()).rev().find_map(|i| {
        let t = tok(i);
        let op = if t.starts_with(b"rg") {
            "rg"
        } else if t.starts_with(b"g") {
            "g"
        } else if t.starts_with(b"k") {
            "k"
        } else {
            return None;
        };
        is_num(tok(i - 1)).then_some((i, op))
    })?;
    let mut first = i;
    while first > 0 && i - first < 4 && is_num(tok(first - 1)) {
        first -= 1;
    }
    let c: Vec<f64> = (first..i)
        .filter_map(|j| std::str::from_utf8(tok(j)).ok()?.parse().ok())
        .collect();
    match (op, c.len()) {
        ("g", _) => Some(Color::Gray(c[0])),
        ("rg", 3..) => Some(Color::Rgb(c[0], c[1], c[2])),
        ("k", 4) => Some(Color::Cmyk(c[0], c[1], c[2], c[3])),
        _ => None,
    }
}

/// pdf-lib's `PDFAcroField.setFontSize`.
fn set_font_size(pdf: &mut Document, id: ObjectId, size: f64) -> Result<()> {
    let field = full_name(pdf, id);
    let da = field_da(pdf, id).ok_or_else(|| {
        form_error(
            "MissingDAEntryError",
            format!("No /DA (default appearance) entry found for field: {field}"),
        )
    })?;
    let last = last_tf(&da, false).ok_or_else(|| {
        form_error(
            "MissingTfOperatorError",
            format!("No Tf operator found for DA of field: {field}"),
        )
    })?;
    let (start, end, font, _) = last;
    let mut out = da[..start].to_vec();
    out.extend_from_slice(b" /");
    out.extend_from_slice(&font);
    out.push(b' ');
    write_num(&mut out, size);
    out.extend_from_slice(b" Tf ");
    out.extend_from_slice(&da[end..]);
    set_da(pdf, id, out)
}

// ------------------------------------------------------------ errors

/// A pdf-lib form error: Dart throws the class `name` with `message`.
fn form_error(name: &str, message: impl Into<String>) -> Error {
    Error::new(ERR_FORM, format!("{name}\u{0}{}", message.into()))
}

// ------------------------------------------------------------ colors

#[derive(Clone, Copy, Debug, PartialEq)]
enum Color {
    Gray(f64),
    Rgb(f64, f64, f64),
    Cmyk(f64, f64, f64, f64),
}

/// `componentsToColor`.
fn color_from(comps: &[f64], scale: f64) -> Option<Color> {
    let c = |i: usize| comps[i] * scale;
    match comps.len() {
        1 => Some(Color::Gray(c(0))),
        3 => Some(Color::Rgb(c(0), c(1), c(2))),
        4 => Some(Color::Cmyk(c(0), c(1), c(2), c(3))),
        _ => None,
    }
}

fn color_parts(c: Color) -> Vec<f64> {
    match c {
        Color::Gray(g) => vec![g],
        Color::Rgb(r, g, b) => vec![r, g, b],
        Color::Cmyk(c, m, y, k) => vec![c, m, y, k],
    }
}

/// A color from Dart: `[type, c1..c4]`, type 0 is "none".
fn color_arg(v: &[f64]) -> Option<Color> {
    match v.first().map(|t| *t as i32) {
        Some(1) => Some(Color::Gray(v[1])),
        Some(2) => Some(Color::Rgb(v[1], v[2], v[3])),
        Some(3) => Some(Color::Cmyk(v[1], v[2], v[3], v[4])),
        _ => None,
    }
}

const BLACK: Color = Color::Rgb(0.0, 0.0, 0.0);

// ------------------------------------------------------------ operators

#[derive(Default)]
struct Ops(Vec<u8>);

impl Ops {
    fn op(&mut self, args: &[f64], op: &str) {
        for a in args {
            write_num(&mut self.0, *a);
            self.0.push(b' ');
        }
        self.0.extend_from_slice(op.as_bytes());
        self.0.push(b'\n');
    }
    fn fill(&mut self, c: Color) {
        let op = ["g", "rg", "k"][color_parts(c).len() / 2];
        self.op(&color_parts(c), op);
    }
    fn stroke(&mut self, c: Color) {
        let op = ["G", "RG", "K"][color_parts(c).len() / 2];
        self.op(&color_parts(c), op);
    }
    fn cm(&mut self, m: [f64; 6]) {
        self.op(&m, "cm");
    }
    fn translate(&mut self, x: f64, y: f64) {
        self.cm([1.0, 0.0, 0.0, 1.0, x, y]);
    }
    fn rotate_degrees(&mut self, deg: f64) {
        let a = deg * PI / 180.0;
        self.cm([a.cos(), a.sin(), -a.sin(), a.cos(), 0.0, 0.0]);
    }
    fn font(&mut self, name: &str, size: f64) {
        self.0.push(b'/');
        self.0.extend_from_slice(name.as_bytes());
        self.0.push(b' ');
        self.op(&[size], "Tf");
    }
}

/// `drawRectangle` with no rotate or skew.
fn rectangle(o: &mut Ops, r: [f64; 4], border_width: f64, color: Option<Color>, border: Option<Color>) {
    let [x, y, w, h] = r;
    o.op(&[], "q");
    if let Some(c) = color {
        o.fill(c);
    }
    if let Some(c) = border {
        o.stroke(c);
    }
    o.op(&[border_width], "w");
    o.op(&[], "[] 0 d");
    o.translate(x, y);
    o.rotate_degrees(0.0);
    o.cm([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
    o.op(&[0.0, 0.0], "m");
    o.op(&[0.0, h], "l");
    o.op(&[w, h], "l");
    o.op(&[w, 0.0], "l");
    o.op(&[], "h");
    paint(o, color.is_some(), border.is_some(), border_width);
    o.op(&[], "Q");
}

fn paint(o: &mut Ops, fill: bool, stroke: bool, border_width: f64) {
    let truthy = border_width != 0.0 && !border_width.is_nan();
    let op = if fill && truthy {
        "B"
    } else if fill {
        "f"
    } else if stroke {
        "S"
    } else {
        "h"
    };
    o.op(&[], op);
}

const KAPPA: f64 = 4.0 * ((std::f64::consts::SQRT_2 - 1.0) / 3.0);

/// `drawEllipse` with no rotate (the old `drawEllipsePath`).
fn ellipse(o: &mut Ops, x: f64, y: f64, scale: f64, border_width: f64, color: Option<Color>, border: Option<Color>) {
    o.op(&[], "q");
    if let Some(c) = color {
        o.fill(c);
    }
    if let Some(c) = border {
        o.stroke(c);
    }
    o.op(&[border_width], "w");
    o.op(&[], "[] 0 d");
    let (bx, by) = (x - scale, y - scale);
    let ox = scale * KAPPA;
    let (xe, ye, xm, ym) = (bx + scale * 2.0, by + scale * 2.0, bx + scale, by + scale);
    o.op(&[], "q");
    o.op(&[bx, ym], "m");
    o.op(&[bx, ym - ox, xm - ox, by, xm, by], "c");
    o.op(&[xm + ox, by, xe, ym - ox, xe, ym], "c");
    o.op(&[xe, ym + ox, xm + ox, ye, xm, ye], "c");
    o.op(&[xm - ox, ye, bx, ym + ox, bx, ym], "c");
    o.op(&[], "Q");
    paint(o, color.is_some(), border.is_some(), border_width);
    o.op(&[], "Q");
}

/// `rotateInPlace`.
fn rotate_in_place(o: &mut Ops, w: f64, h: f64, rotation: i32) {
    let (x, y) = match rotation {
        0 => (0.0, 0.0),
        90 => (w, 0.0),
        180 => (w, h),
        270 => (0.0, h),
        _ => return,
    };
    o.translate(x, y);
    o.rotate_degrees(rotation as f64);
}

/// `reduceRotation`.
fn reduce_rotation(deg: f64) -> i32 {
    let q = (deg / 90.0) % 4.0;
    match q {
        1.0 => 90,
        2.0 => 180,
        3.0 => 270,
        _ => 0,
    }
}

struct Line {
    text: String,
    /// the operators that show the text (`FormFont::show`)
    ops: Vec<u8>,
    x: f64,
    y: f64,
    height: f64,
}

/// `drawTextLines`.
fn text_lines(o: &mut Ops, lines: &[Line], color: Color, font: &str, size: f64) {
    o.op(&[], "BT");
    o.fill(color);
    o.font(font, size);
    for l in lines {
        o.op(&[1.0, 0.0, 0.0, 1.0, l.x, l.y], "Tm");
        o.0.extend_from_slice(&l.ops);
        o.0.push(b'\n');
    }
    o.op(&[], "ET");
}

struct Box4 {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    border_width: f64,
}

fn clip(o: &mut Ops, b: &Box4, padding: f64) {
    let cx = b.x + b.border_width / 2.0 + padding;
    let cy = b.y + b.border_width / 2.0 + padding;
    let cw = b.w - (b.border_width / 2.0 + padding) * 2.0;
    let ch = b.h - (b.border_width / 2.0 + padding) * 2.0;
    o.op(&[cx, cy], "m");
    o.op(&[cx, cy + ch], "l");
    o.op(&[cx + cw, cy + ch], "l");
    o.op(&[cx + cw, cy], "l");
    o.op(&[], "h");
    o.op(&[], "W");
    o.op(&[], "n");
}

fn marked_text(o: &mut Ops, lines: &[Line], color: Color, font: &str, size: f64) {
    o.op(&[], "/Tx BMC");
    o.op(&[], "q");
    text_lines(o, lines, color, font, size);
    o.op(&[], "Q");
    o.op(&[], "EMC");
}

// ------------------------------------------------------------ text layout

const MIN_FONT_SIZE: f64 = 4.0;
/// Most cells of a combed text field. Each cell is one text operator.
const MAX_COMB_CELLS: usize = 1000;
const MAX_FONT_SIZE: f64 = 500.0;

#[derive(Clone, Copy)]
struct Bounds {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

/// pdf-lib's `cleanText`.
fn clean_text(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '\t' | '\u{85}' | '\u{2028}' | '\u{2029}' => out.push_str("    "),
            '\x08' | '\x0b' => {}
            _ => out.push(c),
        }
    }
    out
}

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\x0c' | '\r' | '\x0b')
}

/// `mergeLines`.
fn merge_lines(text: &str) -> String {
    text.chars().map(|c| if is_newline(c) { ' ' } else { c }).collect()
}

/// JavaScript's `\s` (and what `trim` removes).
fn js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\x0b' | '\x0c' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}'
    )
}

/// `computeFontSize`.
fn compute_font_size(lines: &[String], f: &dyn FormFont, b: Bounds, multiline: bool) -> Result<f64> {
    let mut size = MIN_FONT_SIZE;
    while size < MAX_FONT_SIZE {
        let mut used = 0usize;
        for line in lines {
            used += 1;
            let words: Vec<&str> = line.split(' ').collect();
            let mut left = b.w;
            for (i, w) in words.iter().enumerate() {
                let word = if i == words.len() - 1 {
                    w.to_string()
                } else {
                    format!("{w} ")
                };
                let width = f.width(&word, size)?;
                left -= width;
                if left <= 0.0 {
                    used += 1;
                    left = b.w - width;
                }
            }
        }
        if !multiline && used > lines.len() {
            return Ok(size - 1.0);
        }
        let height = f.height(size, true);
        let line_height = height + height * 0.2;
        if line_height * used as f64 > b.h.abs() {
            return Ok(size - 1.0);
        }
        size += 1.0;
    }
    Ok(size)
}

fn auto(size: Option<f64>) -> Option<f64> {
    size.filter(|s| *s != 0.0)
}

fn align_x(alignment: i32, b: Bounds, width: f64) -> f64 {
    match alignment {
        1 => b.x + (b.w / 2.0) - (width / 2.0),
        2 => b.x + b.w - width,
        _ => b.x,
    }
}

/// `layoutSinglelineText`.
fn layout_single(text: &str, alignment: i32, size: Option<f64>, f: &dyn FormFont, b: Bounds) -> Result<(Line, f64)> {
    let line = merge_lines(&clean_text(text));
    let size = match auto(size) {
        Some(s) => s,
        None => compute_font_size(std::slice::from_ref(&line), f, b, false)?,
    };
    let ops = f.show(&line, size)?;
    let width = f.width(&line, size)?;
    let height = f.height(size, false);
    let x = align_x(alignment, b, width);
    let y = b.y + (b.h / 2.0 - height / 2.0);
    Ok((
        Line {
            text: line,
            ops,
            x,
            y,
            height,
        },
        size,
    ))
}

/// `splitOutLines`: (line, width, remainder).
fn split_out(input: &[char], max_width: f64, f: &dyn FormFont, size: f64) -> Result<(String, f64, Option<Vec<char>>)> {
    let mut last = input.len();
    while last > 0 {
        let line: String = input[..last].iter().collect();
        let width = f.width(&line, size)?;
        if width < max_width {
            let rest = &input[last..];
            return Ok((line, width, (!rest.is_empty()).then(|| rest.to_vec())));
        }
        // `lastIndexOfWhitespace`: from `line.length` down to 1
        last = (1..last).rev().find(|&i| js_space(input[i])).unwrap_or(0);
    }
    let line: String = input.iter().collect();
    let width = f.width(&line, size)?;
    Ok((line, width, None))
}

/// `layoutMultilineText`: lines, font size, line height.
fn layout_multi(
    text: &str,
    alignment: i32,
    size: Option<f64>,
    f: &dyn FormFont,
    b: Bounds,
) -> Result<(Vec<Line>, f64, f64)> {
    let lines: Vec<String> = clean_text(text).split(is_newline).map(str::to_string).collect();
    let size = match auto(size) {
        Some(s) => s,
        None => compute_font_size(&lines, f, b, true)?,
    };
    let height = f.height(size, true);
    let line_height = height + height * 0.2;
    let mut out = Vec::new();
    let mut y = b.y + b.h;
    for line in &lines {
        let mut rest: Option<Vec<char>> = Some(line.chars().collect());
        while let Some(input) = rest {
            let (text, width, remainder) = split_out(&input, b.w, f, size)?;
            let x = align_x(alignment, b, width);
            y -= line_height;
            let ops = f.show(&text, size)?;
            out.push(Line {
                text,
                ops,
                x,
                y,
                height,
            });
            // only lines we split ourselves are trimmed
            rest = remainder.map(|r| {
                let s: String = r.into_iter().collect();
                s.trim_matches(js_space).chars().collect()
            });
        }
    }
    Ok((out, size, line_height))
}

/// `layoutCombedText`.
fn layout_combed(text: &str, size: Option<f64>, f: &dyn FormFont, b: Bounds, cells: usize) -> Result<(Vec<Line>, f64)> {
    let line: Vec<char> = merge_lines(&clean_text(text)).chars().collect();
    let length = line.iter().map(|c| c.len_utf16()).sum::<usize>();
    if length > cells {
        return Err(form_error(
            "CombedTextLayoutError",
            format!("Failed to layout combed text as lineLength={length} is greater than cellCount={cells}"),
        ));
    }
    let cell_width = b.w / cells as f64;
    let size = match auto(size) {
        Some(s) => s,
        None => {
            // `computeCombedFontSize`
            let mut s = MIN_FONT_SIZE;
            'grow: loop {
                if s >= MAX_FONT_SIZE {
                    break s;
                }
                for c in &line {
                    if f.width(&c.to_string(), s)? > cell_width * 0.75 {
                        break 'grow s - 1.0;
                    }
                }
                if f.height(s, false) > b.h {
                    break s - 1.0;
                }
                s += 1.0;
            }
        }
    };
    let height = f.height(size, false);
    let y = b.y + (b.h / 2.0 - height / 2.0);
    let all: String = line.iter().collect();
    let mut out = Vec::with_capacity(cells.min(MAX_COMB_CELLS));
    for cell in 0..cells {
        let c: String = line.get(cell).map(|c| c.to_string()).unwrap_or_default();
        let width = f.width(&c, size)?;
        let center = b.x + (cell_width * cell as f64 + cell_width / 2.0);
        out.push(Line {
            text: all.clone(),
            ops: f.show(&c, size)?,
            x: center - width / 2.0,
            y,
            height,
        });
    }
    Ok((out, size))
}

// ------------------------------------------------------------ widgets

struct WidgetLook {
    rect: [f64; 4],
    border_width: f64,
    rotation: i32,
    /// width and height after the rotation
    w: f64,
    h: f64,
    border: Option<Color>,
    bg: Vec<f64>,
    da: Option<Vec<u8>>,
}

/// `getRectangle`: x, y, width, height.
fn rect(pdf: &Document, d: &Dictionary) -> [f64; 4] {
    let Some(Object::Array(r)) = get(pdf, d, b"Rect") else {
        return [0.0; 4];
    };
    let v: Vec<f64> = r.iter().filter_map(|o| deref(pdf, o).and_then(as_f64)).collect();
    if v.len() != 4 {
        return [0.0; 4];
    }
    [v[0], v[1], v[2] - v[0], v[3] - v[1]]
}

/// The numbers of a `/BC` or `/BG` array (direct numbers only).
fn comps(pdf: &Document, mk: Option<&Dictionary>, key: &[u8]) -> Option<Vec<f64>> {
    match get(pdf, mk?, key)? {
        Object::Array(a) => Some(a.iter().filter_map(as_f64).collect()),
        _ => None,
    }
}

fn look(pdf: &Document, widget: ObjectId) -> Option<WidgetLook> {
    let d = dict_of(pdf, widget)?;
    let r = rect(pdf, d);
    let mk = get_dict(pdf, d, b"MK");
    let border_width = match get_dict(pdf, d, b"BS") {
        Some(bs) => get_num(pdf, bs, b"W").unwrap_or(1.0),
        None => 0.0,
    };
    let rotation = reduce_rotation(mk.and_then(|m| get_num(pdf, m, b"R")).unwrap_or(0.0));
    let (w, h) = if rotation == 90 || rotation == 270 {
        (r[3], r[2])
    } else {
        (r[2], r[3])
    };
    Some(WidgetLook {
        rect: r,
        border_width,
        rotation,
        w,
        h,
        border: comps(pdf, mk, b"BC").and_then(|c| color_from(&c, 1.0)),
        bg: comps(pdf, mk, b"BG").unwrap_or_default(),
        da: own_da(pdf, widget),
    })
}

fn appearances(pdf: &Document, widget: ObjectId) -> Option<&Dictionary> {
    get_dict(pdf, dict_of(pdf, widget)?, b"AP")
}

/// The normal appearance (stream or dict), references followed.
fn normal(pdf: &Document, widget: ObjectId) -> Option<&Object> {
    get(pdf, appearances(pdf, widget)?, b"N")
}

/// `getOnValue`: the first key of the normal appearance dict that is not
/// `Off`.
fn on_value(pdf: &Document, widget: ObjectId) -> Option<Vec<u8>> {
    match normal(pdf, widget)? {
        Object::Dictionary(n) => n.iter().map(|(k, _)| k).find(|k| k.as_slice() != b"Off").cloned(),
        _ => None,
    }
}

fn appearance_state(pdf: &Document, widget: ObjectId) -> Option<Vec<u8>> {
    match dict_of(pdf, widget).and_then(|d| get(pdf, d, b"AS"))? {
        Object::Name(n) => Some(n.clone()),
        _ => None,
    }
}

fn set_appearance_state(pdf: &mut Document, widget: ObjectId, state: &[u8]) -> Result<()> {
    dict_mut(pdf, widget)?.set("AS", Object::Name(state.to_vec()));
    Ok(())
}

/// A form XObject, like pdf-lib's `createAppearanceStream`.
fn appearance_stream(
    pdf: &mut Document,
    ops: &[u8],
    w: f64,
    h: f64,
    resources: Option<Dictionary>,
) -> Result<ObjectId> {
    let mut d = Dictionary::new();
    d.set("BBox", Object::Array(vec![num(0.0), num(0.0), num(w), num(h)]));
    d.set(
        "Matrix",
        Object::Array([1.0, 0.0, 0.0, 1.0, 0.0, 0.0].map(num).to_vec()),
    );
    if let Some(r) = resources {
        d.set("Resources", Object::Dictionary(r));
    }
    d.set("Type", name("XObject"));
    d.set("Subtype", name("Form"));
    d.set("Filter", name("FlateDecode"));
    Ok(pdf.add_object(Object::Stream(Stream::new(d, draw::deflate(ops)?))))
}

fn font_resources(font: &FieldFont) -> Dictionary {
    let mut fonts = Dictionary::new();
    fonts.set(font.f.name().as_bytes().to_vec(), Object::Reference(font.id));
    let mut r = Dictionary::new();
    r.set("Font", Object::Dictionary(fonts));
    r
}

/// `updateWidgetAppearances`: `/N`, and `/D` or none; `/R` is removed.
fn set_widget_appearances(pdf: &mut Document, widget: ObjectId, n: Object, d: Option<Object>) -> Result<()> {
    let ap = sub_dict_mut(pdf, widget, b"AP")?;
    ap.set("N", n);
    ap.remove(b"R");
    match d {
        Some(d) => ap.set("D", d),
        None => {
            ap.remove(b"D");
        }
    }
    Ok(())
}

/// `updateDefaultAppearance`: color and font of the `/DA`.
fn da_text(color: Color, font: Option<&str>, size: f64) -> Vec<u8> {
    let mut o = Ops::default();
    o.fill(color);
    o.font(font.unwrap_or("dummy__noop"), size);
    let mut da = o.0;
    da.pop(); // the last newline: the two parts are joined with '\n'
    da
}

// ------------------------------------------------------------ appearances

/// The text color and font size of a widget, and where they go: the
/// widget when it has its own, else the field.
struct Defaults {
    color: Color,
    size: Option<f64>,
    on_widget: bool,
}

fn defaults(pdf: &Document, field: ObjectId, l: &WidgetLook) -> Defaults {
    let fda = field_da(pdf, field);
    let widget_color = da_color(l.da.as_deref());
    let widget_size = da_font_size(l.da.as_deref());
    Defaults {
        color: widget_color.or_else(|| da_color(fda.as_deref())).unwrap_or(BLACK),
        size: widget_size.or_else(|| da_font_size(fda.as_deref())),
        on_widget: widget_color.is_some() || widget_size.is_some(),
    }
}

fn write_da(pdf: &mut Document, field: ObjectId, widget: ObjectId, on_widget: bool, da: Vec<u8>) -> Result<()> {
    set_da(pdf, if on_widget { widget } else { field }, da)
}

/// The check box and radio button appearances: on and off, normal and
/// down (`defaultCheckBoxAppearanceProvider`, `...RadioGroup...`).
fn on_off_appearance(doc: &mut Doc, field: ObjectId, kind: i32, widget: ObjectId, on: &[u8]) -> Result<()> {
    let pdf = &mut doc.pdf;
    let Some(l) = look(pdf, widget) else { return Ok(()) };
    let widget_color = da_color(l.da.as_deref());
    let color = widget_color
        .or_else(|| da_color(field_da(pdf, field).as_deref()))
        .unwrap_or(BLACK);
    let da = da_text(color, None, 0.0);
    write_da(pdf, field, widget, widget_color.is_some(), da)?;
    let border = l.border.or(Some(BLACK));
    let bw = l.border_width;
    let draw = |bg: Option<Color>, filled: bool| {
        let mut o = Ops::default();
        rotate_in_place(&mut o, l.rect[2], l.rect[3], l.rotation);
        let (w, h) = (l.w - bw, l.h - bw);
        if kind == CHECK_BOX {
            if filled {
                o.op(&[], "q");
            }
            rectangle(&mut o, [bw / 2.0, bw / 2.0, w, h], bw, bg, border);
            if filled {
                check_mark(&mut o, w / 2.0, h / 2.0, w.min(h) / 2.0, color);
                o.op(&[], "Q");
            }
        } else {
            let (x, y) = (l.w / 2.0, l.h / 2.0);
            let scale = w.min(h) / 2.0;
            if filled {
                o.op(&[], "q");
            }
            ellipse(&mut o, x, y, scale, bw, bg, border);
            if filled {
                ellipse(&mut o, x, y, scale * 0.45, 0.0, Some(color), None);
                o.op(&[], "Q");
            }
        }
        o.0
    };
    let mut dicts = Vec::new();
    for scale in [1.0, 0.8] {
        let bg = color_from(&l.bg, scale);
        let on_ref = appearance_stream(pdf, &draw(bg, true), l.rect[2], l.rect[3], None)?;
        let off_ref = appearance_stream(pdf, &draw(bg, false), l.rect[2], l.rect[3], None)?;
        let mut d = Dictionary::new();
        d.set(on.to_vec(), Object::Reference(on_ref));
        d.set("Off", Object::Reference(off_ref));
        dicts.push(Object::Dictionary(d));
    }
    let down = dicts.pop();
    set_widget_appearances(pdf, widget, dicts.pop().unwrap(), down)
}

/// `drawCheckMark`, thickness 1.5.
fn check_mark(o: &mut Ops, x: f64, y: f64, size: f64, color: Color) {
    let (p2x, p2y) = (-1.0 + 0.75, -1.0 + 0.51);
    let (p3y, p3x) = (1.0 - 0.525, 1.0 - 0.31);
    let p1x = -1.0 + 0.325;
    let p1y = -((p1x - p2x) * (p3x - p2x)) / (p3y - p2y) + p2y;
    o.op(&[], "q");
    o.stroke(color);
    o.op(&[1.5], "w");
    o.translate(x, y);
    o.op(&[p1x * size, p1y * size], "m");
    o.op(&[p2x * size, p2y * size], "l");
    o.op(&[p3x * size, p3y * size], "l");
    o.op(&[], "S");
    o.op(&[], "Q");
}

/// The text field, dropdown, option list and button appearances.
fn font_appearance(doc: &mut Doc, field: ObjectId, kind: i32, widget: ObjectId, font: &FieldFont) -> Result<()> {
    let pdf = &mut doc.pdf;
    let Some(l) = look(pdf, widget) else { return Ok(()) };
    let def = defaults(pdf, field, &l);
    let f = font.f.as_ref();
    let fname = f.name();
    let bw = l.border_width;
    let field_dict = dict_of(pdf, field).cloned().unwrap_or_default();
    let fl = flags(pdf, field);
    let mut normal_ops = Ops::default();
    rotate_in_place(&mut normal_ops, l.rect[2], l.rect[3], l.rotation);
    let mut down_ops = None;
    let bg = color_from(&l.bg, 1.0);
    let outer = Box4 {
        x: bw / 2.0,
        y: bw / 2.0,
        w: l.w - bw,
        h: l.h - bw,
        border_width: bw,
    };
    let size = match kind {
        BUTTON => {
            let mk = get_dict(pdf, dict_of(pdf, widget).unwrap(), b"MK");
            let caption = |k: &[u8]| mk.and_then(|m| get(pdf, m, k)).and_then(text_of);
            let normal_text = caption(b"CA").unwrap_or_default();
            let down_text = caption(b"AC").unwrap_or_else(|| normal_text.clone());
            let b = Bounds {
                x: bw,
                y: bw,
                w: l.w - bw * 2.0,
                h: l.h - bw * 2.0,
            };
            let (n, ns) = layout_single(&normal_text, 1, def.size, f, b)?;
            let (d, ds) = layout_single(&down_text, 1, def.size, f, b)?;
            let size = ns.min(ds);
            let mut down = Ops::default();
            rotate_in_place(&mut down, l.rect[2], l.rect[3], l.rotation);
            for (o, line, bg) in [(&mut normal_ops, n, bg), (&mut down, d, color_from(&l.bg, 0.8))] {
                o.op(&[], "q");
                rectangle(o, [outer.x, outer.y, outer.w, outer.h], bw, bg, l.border);
                text_lines(o, &[line], def.color, fname, size);
                o.op(&[], "Q");
            }
            down_ops = Some(down);
            size
        }
        OPTION_LIST => {
            let mut options: Vec<String> = choice_options(pdf, &field_dict).into_iter().map(|o| o.2).collect();
            let selected = shown_values(pdf, field);
            if fl & SORT != 0 {
                // JavaScript's default sort: by UTF-16 code units
                options.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
            }
            let text = options.join("\n");
            let b = Bounds {
                x: bw + 1.0,
                y: bw + 1.0,
                w: l.w - (bw + 1.0) * 2.0,
                h: l.h - (bw + 1.0) * 2.0,
            };
            let (lines, size, line_height) = layout_multi(&text, 0, def.size, f, b)?;
            let o = &mut normal_ops;
            o.op(&[], "q");
            rectangle(o, [outer.x, outer.y, outer.w, outer.h], bw, bg, l.border);
            let blue = Color::Rgb(153.0 / 255.0, 193.0 / 255.0, 218.0 / 255.0);
            for line in lines.iter().filter(|line| selected.contains(&line.text)) {
                let r = [
                    line.x - 1.0,
                    line.y - (line_height - line.height) / 2.0,
                    outer.w - bw,
                    line.height + (line_height - line.height) / 2.0,
                ];
                rectangle(o, r, 0.0, Some(blue), None);
            }
            clip(o, &outer, 1.0);
            marked_text(o, &lines, def.color, fname, size);
            o.op(&[], "Q");
            size
        }
        _ => {
            // text field and dropdown
            let (lines, size, padding) = if kind == DROPDOWN {
                let text = shown_values(pdf, field).into_iter().next().unwrap_or_default();
                let b = Bounds {
                    x: bw + 1.0,
                    y: bw + 1.0,
                    w: l.w - (bw + 1.0) * 2.0,
                    h: l.h - (bw + 1.0) * 2.0,
                };
                let (line, size) = layout_single(&text, 0, def.size, f, b)?;
                (vec![line], size, 1.0)
            } else {
                let text = text_value(pdf, field).unwrap_or_default();
                let max_len = get_num(pdf, &field_dict, b"MaxLen");
                // a file can say `/MaxLen 4000000000000`: more cells than
                // MAX_COMB_CELLS are laid out as one normal line
                let combed = fl & COMB != 0
                    && fl & (MULTILINE | PASSWORD | FILE_SELECT) == 0
                    && max_len.is_some_and(|m| m <= MAX_COMB_CELLS as f64);
                let padding = if combed { 0.0 } else { 1.0 };
                let b = Bounds {
                    x: bw + padding,
                    y: bw + padding,
                    w: l.w - (bw + padding) * 2.0,
                    h: l.h - (bw + padding) * 2.0,
                };
                let alignment = alignment(pdf, &field_dict);
                if fl & MULTILINE != 0 {
                    let (lines, size, _) = layout_multi(&text, alignment, def.size, f, b)?;
                    (lines, size, padding)
                } else if combed {
                    let cells = max_len.unwrap_or(0.0).max(0.0) as usize;
                    let (lines, size) = layout_combed(&text, def.size, f, b, cells)?;
                    (lines, size, padding)
                } else {
                    let (line, size) = layout_single(&text, alignment, def.size, f, b)?;
                    (vec![line], size, padding)
                }
            };
            let o = &mut normal_ops;
            o.op(&[], "q");
            rectangle(o, [outer.x, outer.y, outer.w, outer.h], bw, bg, l.border);
            clip(o, &outer, padding);
            marked_text(o, &lines, def.color, fname, size);
            o.op(&[], "Q");
            size
        }
    };
    let da = da_text(def.color, Some(fname), size);
    write_da(pdf, field, widget, def.on_widget, da)?;
    let (w, h) = (l.rect[2], l.rect[3]);
    let n = appearance_stream(pdf, &normal_ops.0, w, h, Some(font_resources(font)))?;
    let d = match down_ops {
        Some(o) => Some(Object::Reference(appearance_stream(
            pdf,
            &o.0,
            w,
            h,
            Some(font_resources(font)),
        )?)),
        None => None,
    };
    set_widget_appearances(pdf, widget, Object::Reference(n), d)
}

fn alignment(pdf: &Document, d: &Dictionary) -> i32 {
    match get_num(pdf, d, b"Q") {
        Some(1.0) => 1,
        Some(2.0) => 2,
        _ => 0,
    }
}

/// pdf-lib's `needsAppearancesUpdate`.
fn needs_update(doc: &Doc, field: ObjectId, kind: i32) -> bool {
    let pdf = &doc.pdf;
    match kind {
        SIGNATURE => false,
        CHECK_BOX | RADIO_GROUP => widgets(pdf, field).into_iter().any(|w| match normal(pdf, w) {
            Some(Object::Dictionary(n)) => appearance_state(pdf, w).is_some_and(|s| !n.has(&s)),
            _ => true,
        }),
        _ => {
            doc.form.dirty.contains(&field)
                || widgets(pdf, field)
                    .into_iter()
                    .any(|w| !matches!(normal(pdf, w), Some(Object::Stream(_))))
        }
    }
}

/// pdf-lib's `defaultUpdateAppearances(font)`.
fn update_field(doc: &mut Doc, field: ObjectId, kind: i32, font: &FieldFont) -> Result<()> {
    let list = widgets(&doc.pdf, field);
    match kind {
        SIGNATURE => return Ok(()),
        CHECK_BOX | RADIO_GROUP => {
            for w in list {
                let on = match on_value(&doc.pdf, w) {
                    Some(on) => on,
                    None if kind == CHECK_BOX => b"Yes".to_vec(),
                    None => continue,
                };
                on_off_appearance(doc, field, kind, w, &on)?;
            }
            // pdf-lib's radio group does not mark the field as clean
            if kind == RADIO_GROUP {
                return Ok(());
            }
        }
        _ => {
            for w in list {
                font_appearance(doc, field, kind, w, font)?;
            }
            if kind == BUTTON {
                return Ok(());
            }
        }
    }
    doc.form.dirty.remove(&field);
    Ok(())
}

/// pdf-lib's `updateFieldAppearances(font)`.
fn update_all(doc: &mut Doc, font: Option<ObjectId>) -> Result<()> {
    let id = match font {
        Some(id) => id,
        None => default_font(doc)?,
    };
    let font = form_font(doc, id)?;
    for (field, kind) in all_fields(&doc.pdf) {
        if needs_update(doc, field, kind) {
            update_field(doc, field, kind, &font)?;
        }
    }
    Ok(())
}

/// For save (document.rs): update the appearances when `getForm` was
/// called, like pdf-lib's `save({ updateFieldAppearances: true })`.
pub fn before_save(doc: &mut Doc) -> Result<()> {
    if doc.form.accessed {
        update_all(doc, None)?;
    }
    Ok(())
}

// ------------------------------------------------------------ values

fn text_value(pdf: &Document, field: ObjectId) -> Option<String> {
    inherited(pdf, field, b"V").and_then(text_of)
}

/// The options of a choice field: (value, display, display ?? value).
fn choice_options(pdf: &Document, d: &Dictionary) -> Vec<(Object, Object, String)> {
    let str_obj = |o: &Object| matches!(o, Object::String(..));
    match get(pdf, d, b"Opt") {
        Some(o @ Object::String(..)) => vec![(o.clone(), o.clone(), text_of(o).unwrap_or_default())],
        Some(Object::Array(items)) => items
            .iter()
            .filter_map(|item| match deref(pdf, item)? {
                o @ Object::String(..) => Some((o.clone(), o.clone(), text_of(o)?)),
                Object::Array(pair) => {
                    let first = deref(pdf, pair.first()?).filter(|o| str_obj(o))?;
                    let second = pair.get(1).and_then(|o| deref(pdf, o)).filter(|o| str_obj(o));
                    let display = second.unwrap_or(first);
                    Some((first.clone(), display.clone(), text_of(display)?))
                }
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn choice_values(pdf: &Document, field: ObjectId) -> Vec<String> {
    choice_value_objects(pdf, field).iter().filter_map(text_of).collect()
}

/// The string objects of `/V`, as they are in the file.
fn choice_value_objects(pdf: &Document, field: ObjectId) -> Vec<Object> {
    match inherited(pdf, field, b"V") {
        Some(o @ Object::String(..)) => vec![o.clone()],
        Some(Object::Array(items)) => items
            .iter()
            .filter_map(|o| deref(pdf, o))
            .filter(|o| matches!(o, Object::String(..)))
            .cloned()
            .collect(),
        _ => Vec::new(),
    }
}

/// The options of a field: (export value object, export text, display text).
fn choice_pairs(pdf: &Document, field: ObjectId) -> Vec<(Object, String, String)> {
    let d = dict_of(pdf, field).cloned().unwrap_or_default();
    choice_options(pdf, &d)
        .into_iter()
        .map(|(value, _, shown)| {
            let export = text_of(&value).unwrap_or_default();
            (value, export, shown)
        })
        .collect()
}

/// The selected values as display text: `/V` holds the export value of an
/// option with an export / display pair. pdf-lib returns `/V` as it is.
fn shown_values(pdf: &Document, field: ObjectId) -> Vec<String> {
    let pairs = choice_pairs(pdf, field);
    choice_values(pdf, field)
        .into_iter()
        .map(|v| match pairs.iter().find(|p| p.1 == v) {
            Some(p) => p.2.clone(),
            None => v,
        })
        .collect()
}

/// `PDFAcroChoice.setValues`. A value may be a display text or an export
/// value of an option.
fn set_choice_values(pdf: &mut Document, field: ObjectId, values: Vec<Object>) -> Result<()> {
    let fl = flags(pdf, field);
    let pairs = choice_pairs(pdf, field);
    let texts: Vec<String> = values.iter().filter_map(text_of).collect();
    let index = |v: &String| pairs.iter().position(|p| p.1 == *v || p.2 == *v);
    if fl & COMBO != 0 && fl & EDIT == 0 && !texts.iter().all(|v| index(v).is_some()) {
        return Err(form_error(
            "InvalidAcroFieldValueError",
            "Attempted to set invalid field value",
        ));
    }
    if values.len() > 1 && fl & MULTI_SELECT == 0 {
        return Err(form_error(
            "MultiSelectValueError",
            "Attempted to select multiple values for single-select field",
        ));
    }
    let mut idx: Vec<i64> = texts.iter().map(|v| index(v).map(|i| i as i64).unwrap_or(-1)).collect();
    let dict = dict_mut(pdf, field)?;
    let many = values.len() > 1;
    match values.len() {
        0 => {
            dict.remove(b"V");
        }
        1 => dict.set("V", values.into_iter().next().unwrap()),
        _ => dict.set("V", Object::Array(values)),
    }
    if many {
        // JavaScript's default sort compares the numbers as text
        idx.sort_by_key(|i| i.to_string());
        dict.set("I", Object::Array(idx.into_iter().map(Object::Integer).collect()));
    } else {
        dict.remove(b"I");
    }
    Ok(())
}

/// The radio export values (`getExportValues`), when `/Opt` is there.
fn export_values(pdf: &Document, field: ObjectId) -> Option<Vec<String>> {
    match dict_of(pdf, field).and_then(|d| get(pdf, d, b"Opt"))? {
        o @ Object::String(..) => Some(text_of(o).into_iter().collect()),
        Object::Array(items) => Some(items.iter().filter_map(|o| deref(pdf, o).and_then(text_of)).collect()),
        _ => None,
    }
}

fn on_values(pdf: &Document, field: ObjectId) -> Vec<Vec<u8>> {
    widgets(pdf, field)
        .into_iter()
        .filter_map(|w| on_value(pdf, w))
        .collect()
}

/// The field value as a name (`getValue` of a button), `Off` by default.
fn name_value(pdf: &Document, field: ObjectId) -> Vec<u8> {
    match inherited(pdf, field, b"V") {
        Some(Object::Name(n)) => n.clone(),
        _ => b"Off".to_vec(),
    }
}

/// `PDFAcroCheckBox.setValue` / `PDFAcroRadioButton.setValue`.
fn set_button_value(pdf: &mut Document, field: ObjectId, value: &[u8]) -> Result<()> {
    dict_mut(pdf, field)?.set("V", Object::Name(value.to_vec()));
    for w in widgets(pdf, field) {
        let state = if on_value(pdf, w).as_deref() == Some(value) {
            value.to_vec()
        } else {
            b"Off".to_vec()
        };
        set_appearance_state(pdf, w, &state)?;
    }
    Ok(())
}

fn radio_options(pdf: &Document, field: ObjectId) -> Vec<String> {
    export_values(pdf, field).unwrap_or_else(|| on_values(pdf, field).iter().map(|n| name_text(n)).collect())
}

// ------------------------------------------------------------ create

/// pdf-lib's `splitFieldName`.
fn split_name(name: &str) -> Result<(Vec<&str>, &str)> {
    if name.is_empty() {
        return Err(Error::generic("PDF field names must not be empty strings"));
    }
    let parts: Vec<&str> = name.split('.').collect();
    if parts.iter().any(|p| p.is_empty()) {
        return Err(Error::generic(format!(
            "Periods in PDF field names must be separated by at least one character: \"{name}\""
        )));
    }
    let (last, rest) = parts.split_last().unwrap();
    Ok((rest.to_vec(), last))
}

/// The fields under `parent` (`None`: the AcroForm's `/Fields`).
fn children(pdf: &Document, form: ObjectId, parent: Option<ObjectId>) -> Vec<ObjectId> {
    match parent {
        Some(p) => kids(pdf, p),
        None => dict_of(pdf, form)
            .map(|d| dict_refs(pdf, d.get(b"Fields").ok()))
            .unwrap_or_default(),
    }
}

fn add_child(pdf: &mut Document, form: ObjectId, parent: Option<ObjectId>, child: ObjectId) -> Result<()> {
    let (holder, key) = match parent {
        Some(p) => (p, &b"Kids"[..]),
        None => (form, &b"Fields"[..]),
    };
    array_mut(pdf, holder, key, true)
        .ok_or_else(|| Error::generic("the form has no field list"))?
        .push(Object::Reference(child));
    let d = dict_mut(pdf, child)?;
    match parent {
        Some(p) => d.set("Parent", Object::Reference(p)),
        None => {
            d.remove(b"Parent");
        }
    }
    Ok(())
}

fn already_exists(part: &str) -> Error {
    form_error(
        "FieldAlreadyExistsError",
        format!("A field already exists with the specified name: \"{part}\""),
    )
}

/// pdf-lib's `createTextField` (and the others): `findOrCreateNonTerminals`
/// + `addFieldToParent`.
fn create_field(doc: &mut Doc, kind: i32, full: &str) -> Result<ObjectId> {
    let (parents, terminal) = split_name(full)?;
    let pdf = &mut doc.pdf;
    let form = acroform(pdf, true)?.expect("made");
    let mut parent: Option<ObjectId> = None;
    for part in parents {
        let found = children(pdf, form, parent)
            .into_iter()
            .find(|c| partial_name(pdf, *c).as_deref() == Some(part));
        parent = Some(match found {
            Some(c) if is_non_terminal(pdf, c) => c,
            Some(_) => return Err(already_exists(part)),
            None => {
                let mut d = Dictionary::new();
                d.set("T", text_object(part));
                let id = pdf.add_object(Object::Dictionary(d));
                add_child(pdf, form, parent, id)?;
                id
            }
        });
    }
    if children(pdf, form, parent)
        .into_iter()
        .any(|c| partial_name(pdf, c).as_deref() == Some(terminal))
    {
        return Err(already_exists(terminal));
    }
    let (ft, ff) = match kind {
        BUTTON => ("Btn", PUSH_BUTTON),
        CHECK_BOX => ("Btn", 0),
        RADIO_GROUP => ("Btn", RADIO),
        DROPDOWN => ("Ch", COMBO),
        OPTION_LIST => ("Ch", 0),
        TEXT_FIELD => ("Tx", 0),
        _ => return Err(Error::generic(format!("can not create a field of kind {kind}"))),
    };
    let mut d = Dictionary::new();
    d.set("FT", name(ft));
    if ff != 0 {
        d.set("Ff", Object::Integer(ff));
    }
    d.set("Kids", Object::Array(vec![]));
    d.set("T", text_object(terminal));
    let id = pdf.add_object(Object::Dictionary(d));
    add_child(pdf, form, parent, id)?;
    Ok(id)
}

/// The numbers of `addToPage` from Dart, at their index.
mod at {
    pub const PAGE: usize = 0;
    pub const X: usize = 1;
    pub const Y: usize = 2;
    pub const W: usize = 3;
    pub const H: usize = 4;
    pub const TEXT_COLOR: usize = 5;
    pub const BG: usize = 10;
    pub const BORDER: usize = 15;
    pub const BORDER_WIDTH: usize = 20;
    pub const ROTATE: usize = 21;
    pub const HIDDEN: usize = 22;
    pub const FONT: usize = 23;
    pub const LEN: usize = 24;
}

/// pdf-lib's `createWidget` + `addToPage` / `addOptionToPage`. The
/// defaults of each field type are set in Dart.
fn add_to_page(doc: &mut Doc, field: ObjectId, kind: i32, n: &[f64], text: &str) -> Result<ObjectId> {
    if n.len() < at::LEN {
        return Err(Error::generic("bad form input"));
    }
    let page = ref_from_i64(n[at::PAGE] as i64);
    let degrees = n[at::ROTATE];
    if degrees % 90.0 != 0.0 {
        return Err(Error::generic(format!(
            "`degreesAngle` must be a multiple of 90, but was actually {}",
            js_num(degrees)
        )));
    }
    let bw = n[at::BORDER_WIDTH];
    let (x, y, w, h) = (n[at::X], n[at::Y], n[at::W] + bw, n[at::H] + bw);
    // `rotateRectangle`
    let b = bw / 2.0;
    let [rx, ry, rw, rh] = match reduce_rotation(degrees) {
        90 => [x - h + b, y - b, h, w],
        180 => [x - w + b, y - h + b, w, h],
        270 => [x - b, y - w + b, h, w],
        _ => [x - b, y - b, w, h],
    };
    let mut wd = Dictionary::new();
    wd.set("Type", name("Annot"));
    wd.set("Subtype", name("Widget"));
    wd.set("Rect", Object::Array([rx, ry, rx + rw, ry + rh].map(num).to_vec()));
    wd.set("Parent", Object::Reference(field));
    wd.set("P", Object::Reference(page));
    let mut mk = Dictionary::new();
    if let Some(bg) = color_arg(&n[at::BG..at::BG + 5]) {
        mk.set("BG", Object::Array(color_parts(bg).into_iter().map(num).collect()));
    }
    mk.set("R", num(degrees));
    if kind == BUTTON && !text.is_empty() {
        mk.set("CA", text_object(text));
    }
    if let Some(bc) = color_arg(&n[at::BORDER..at::BORDER + 5]) {
        mk.set("BC", Object::Array(color_parts(bc).into_iter().map(num).collect()));
    }
    wd.set("MK", Object::Dictionary(mk));
    let mut bs = Dictionary::new();
    bs.set("W", num(bw));
    wd.set("BS", Object::Dictionary(bs));
    // Print, and Hidden when asked
    wd.set("F", Object::Integer(if n[at::HIDDEN] != 0.0 { 4 | 2 } else { 4 }));
    let pdf = &mut doc.pdf;
    if let Some(c) = color_arg(&n[at::TEXT_COLOR..at::TEXT_COLOR + 5]) {
        let mut da = field_da(pdf, field).unwrap_or_default();
        da.push(b'\n');
        let mut o = Ops::default();
        o.fill(c);
        o.0.pop();
        da.extend_from_slice(&o.0);
        set_da(pdf, field, da)?;
    }
    let widget = pdf.add_object(Object::Dictionary(wd));
    if kind == CHECK_BOX || kind == RADIO_GROUP {
        let on = if kind == RADIO_GROUP {
            let unison = has_flag(pdf, field, 1 << 25);
            radio_add_opt(pdf, field, text, unison)?.to_string().into_bytes()
        } else {
            b"Yes".to_vec()
        };
        add_widget(pdf, field, widget)?;
        set_appearance_state(pdf, widget, b"Off")?;
        on_off_appearance(doc, field, kind, widget, &on)?;
    } else {
        add_widget(pdf, field, widget)?;
        let font = match n[at::FONT] as i64 {
            0 => default_font(doc)?,
            f => ref_from_i64(f),
        };
        let font = form_font(doc, font)?;
        font_appearance(doc, field, kind, widget, &font)?;
    }
    add_annot(&mut doc.pdf, page, widget)?;
    Ok(widget)
}

/// A number as JavaScript prints it.
fn js_num(v: f64) -> String {
    let mut out = Vec::new();
    write_num(&mut out, v);
    String::from_utf8(out).unwrap_or_default()
}

/// `PDFAcroButton.addOpt` (with `normalizeExportValues`): the index of
/// the option, the appearance state name of the new widget.
fn radio_add_opt(pdf: &mut Document, field: ObjectId, opt: &str, use_existing: bool) -> Result<usize> {
    let existing = export_values(pdf, field).unwrap_or_default();
    let mut list: Vec<Object> = Vec::new();
    for (i, w) in widgets(pdf, field).into_iter().enumerate() {
        list.push(match existing.get(i) {
            Some(v) => text_object(v),
            None => text_object(&on_value(pdf, w).map(|n| name_text(&n)).unwrap_or_default()),
        });
    }
    let found = if use_existing {
        let values: Vec<String> = list.iter().filter_map(text_of).collect();
        values.iter().rposition(|v| v == opt)
    } else {
        None
    };
    list.push(text_object(opt));
    let len = list.len();
    dict_mut(pdf, field)?.set("Opt", Object::Array(list));
    Ok(found.unwrap_or(len - 1))
}

fn add_annot(pdf: &mut Document, page: ObjectId, annot: ObjectId) -> Result<()> {
    array_mut(pdf, page, b"Annots", true)
        .ok_or_else(|| Error::generic("the page is not a dict"))?
        .push(Object::Reference(annot));
    Ok(())
}

// ------------------------------------------------------------ images

/// `createImageAppearanceStream` for `setImage`.
fn image_appearance(pdf: &mut Document, widget: ObjectId, image: ObjectId, alignment: i32) -> Result<()> {
    let Some(l) = look(pdf, widget) else { return Ok(()) };
    let Some(Object::Stream(s)) = pdf.objects.get(&image) else {
        return Err(Error::generic("the image is not embedded in this document"));
    };
    let iw = s.dict.get(b"Width").ok().and_then(as_f64).unwrap_or(1.0);
    let ih = s.dict.get(b"Height").ok().and_then(as_f64).unwrap_or(1.0);
    let bw = l.border_width;
    let (aw, ah) = (l.w - bw * 2.0, l.h - bw * 2.0);
    let scale = (aw / iw).min(ah / ih);
    let (w, h) = (iw * scale, ih * scale);
    let (mut x, mut y) = (bw, bw);
    match alignment {
        1 => {
            x += aw / 2.0 - w / 2.0;
            y += ah / 2.0 - h / 2.0;
        }
        2 => {
            x = l.w - bw - w;
            y = l.h - bw - h;
        }
        _ => {}
    }
    // pdf-lib uses a random suffix; the image ref is unique too
    let image_name = format!("Image-{}", image.0);
    let mut o = Ops::default();
    rotate_in_place(&mut o, l.rect[2], l.rect[3], l.rotation);
    o.op(&[], "q");
    o.translate(x, y);
    o.rotate_degrees(0.0);
    o.cm([w, 0.0, 0.0, h, 0.0, 0.0]);
    o.cm([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
    o.0.push(b'/');
    o.0.extend_from_slice(image_name.as_bytes());
    o.0.extend_from_slice(b" Do\n");
    o.op(&[], "Q");
    let mut xobjects = Dictionary::new();
    xobjects.set(image_name.into_bytes(), Object::Reference(image));
    let mut res = Dictionary::new();
    res.set("XObject", Object::Dictionary(xobjects));
    let n = appearance_stream(pdf, &o.0, l.rect[2], l.rect[3], Some(res))?;
    set_widget_appearances(pdf, widget, Object::Reference(n), None)
}

// ------------------------------------------------------------ flatten, remove

/// Annotation ref -> page, for every page.
fn annot_pages(pdf: &Document) -> (HashSet<ObjectId>, HashMap<ObjectId, ObjectId>) {
    let mut pages = HashSet::new();
    let mut map = HashMap::new();
    for e in page_entries(pdf).unwrap_or_default() {
        pages.insert(e.id);
        if let Some(Object::Array(a)) = dict_of(pdf, e.id).and_then(|d| get(pdf, d, b"Annots")) {
            for item in a {
                if let Object::Reference(r) = item {
                    map.entry(*r).or_insert(e.id);
                }
            }
        }
    }
    (pages, map)
}

/// pdf-lib's `findWidgetPage`: `/P` when it is a page of the document,
/// else the page whose `/Annots` has the widget.
fn widget_page(
    pdf: &Document,
    widget: ObjectId,
    pages: &(HashSet<ObjectId>, HashMap<ObjectId, ObjectId>),
) -> Option<ObjectId> {
    let p = match dict_of(pdf, widget)?.get(b"P") {
        Ok(Object::Reference(p)) if pages.0.contains(p) => Some(*p),
        _ => None,
    };
    p.or_else(|| pages.1.get(&widget).copied())
}

/// pdf-lib's `findWidgetAppearanceRef`: the normal appearance stream (for
/// a check box or radio button, the one of the field value, or `Off`).
fn appearance_ref(pdf: &Document, field: ObjectId, kind: i32, widget: ObjectId) -> Option<ObjectId> {
    let ap = appearances(pdf, widget)?;
    let pick = |n: &Dictionary| -> Option<ObjectId> {
        if kind != CHECK_BOX && kind != RADIO_GROUP {
            return None;
        }
        let value = name_value(pdf, field);
        match n.get(&value).or_else(|_| n.get(b"Off")) {
            Ok(Object::Reference(r)) => Some(*r),
            _ => None,
        }
    };
    let id = match ap.get(b"N").ok()? {
        Object::Reference(r) => match pdf.objects.get(r)? {
            Object::Dictionary(n) => pick(n)?,
            _ => *r,
        },
        Object::Dictionary(n) => pick(n)?,
        _ => return None,
    };
    matches!(pdf.objects.get(&id), Some(Object::Stream(_))).then_some(id)
}

/// pdf-lib's `flatten`.
fn flatten(doc: &mut Doc, update: bool) -> Result<()> {
    if update {
        update_all(doc, None)?;
    }
    let fields = all_fields(&doc.pdf);
    let pages = annot_pages(&doc.pdf);
    for (field, kind) in fields {
        for w in widgets(&doc.pdf, field) {
            // pdf-lib throws here; a broken widget is skipped
            let Some(page) = widget_page(&doc.pdf, w, &pages) else {
                continue;
            };
            let Some(ap) = appearance_ref(&doc.pdf, field, kind, w) else {
                continue;
            };
            let r = dict_of(&doc.pdf, w).map(|d| rect(&doc.pdf, d)).unwrap_or_default();
            let name = draw::xobject_name(doc, page, ap, "FlatWidget")?;
            let mut o = Ops::default();
            o.op(&[], "q");
            o.translate(r[0], r[1]);
            rotate_in_place(&mut o, r[2], r[3], 0);
            o.0.push(b'/');
            o.0.extend_from_slice(&name);
            o.0.extend_from_slice(b" Do\n");
            o.op(&[], "Q");
            draw::append_content(doc, page, &o.0)?;
        }
        remove_field_with(doc, field, &pages)?;
    }
    Ok(())
}

fn remove_annot(pdf: &mut Document, page: ObjectId, annot: ObjectId) {
    if let Some(list) = array_mut(pdf, page, b"Annots", false) {
        list.retain(|o| *o != Object::Reference(annot));
    }
}

/// pdf-lib's `removeField`. Unlike pdf-lib, the widgets are taken out of
/// the `/Annots` of their pages (pdf-lib leaves refs to deleted objects).
fn remove_field_with(
    doc: &mut Doc,
    field: ObjectId,
    pages: &(HashSet<ObjectId>, HashMap<ObjectId, ObjectId>),
) -> Result<()> {
    let pdf = &mut doc.pdf;
    let list = widgets(pdf, field);
    let mut on_pages = HashSet::new();
    for w in &list {
        if let Some(p) = widget_page(pdf, *w, pages) {
            remove_annot(pdf, p, *w);
            on_pages.insert(p);
        }
    }
    for p in on_pages {
        remove_annot(pdf, p, field);
    }
    // `PDFAcroForm.removeField`, up the tree while a parent gets empty
    let form = acroform(pdf, true)?.expect("made");
    let mut node = field;
    for _ in 0..MAX_DEPTH {
        let up = parent(pdf, node);
        let (holder, key) = match up {
            Some(p) => (p, &b"Kids"[..]),
            None => (form, &b"Fields"[..]),
        };
        let Some(siblings) = array_mut(pdf, holder, key, false) else {
            break;
        };
        siblings.retain(|o| *o != Object::Reference(node));
        match up {
            Some(p) if siblings.is_empty() => node = p,
            _ => break,
        }
    }
    for k in kids(pdf, field) {
        pdf.objects.remove(&k);
    }
    pdf.objects.remove(&field);
    doc.form.dirty.remove(&field);
    Ok(())
}

// ------------------------------------------------------------ widgets for Dart

/// `[ref, x, y, width, height, page ref or 0, flags]` + on value + state.
fn widget_info(pdf: &Document, field: ObjectId, out: &mut Out) {
    let pages = annot_pages(pdf);
    let list = widgets(pdf, field);
    out.i64(list.len() as i64);
    for w in list {
        let d = dict_of(pdf, w);
        let r = d.map(|d| rect(pdf, d)).unwrap_or_default();
        out.i64(ref_to_i64(w));
        for v in r {
            out.f64(v);
        }
        out.i64(widget_page(pdf, w, &pages).map(ref_to_i64).unwrap_or(0));
        out.i64(d.and_then(|d| get_num(pdf, d, b"F")).unwrap_or(0.0) as i64);
        out.opt_str(on_value(pdf, w).map(|n| name_text(&n)).as_deref());
        out.opt_str(appearance_state(pdf, w).map(|n| name_text(&n)).as_deref());
    }
}

// ------------------------------------------------------------ in and out

/// Output records for Dart: i64 / f64 little endian, strings as u32
/// length + UTF-8, an optional string with a 0 / 1 byte first.
#[derive(Default)]
struct Out(Vec<u8>);

impl Out {
    fn i64(&mut self, v: i64) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn f64(&mut self, v: f64) {
        self.0.extend_from_slice(&v.to_le_bytes());
    }
    fn str(&mut self, s: &str) {
        self.0.extend_from_slice(&(s.len() as u32).to_le_bytes());
        self.0.extend_from_slice(s.as_bytes());
    }
    fn opt_str(&mut self, s: Option<&str>) {
        match s {
            Some(s) => {
                self.0.push(1);
                self.str(s);
            }
            None => self.0.push(0),
        }
    }
    fn strs(&mut self, list: &[String]) {
        self.i64(list.len() as i64);
        for s in list {
            self.str(s);
        }
    }
    fn fields(&mut self, list: &[(ObjectId, i32)]) {
        self.i64(list.len() as i64);
        for (id, k) in list {
            self.i64(ref_to_i64(*id));
            self.i64(*k as i64);
        }
    }
}

/// The input strings: u32 length + UTF-8 each.
fn strings(bytes: &[u8]) -> Result<Vec<String>> {
    let bad = || Error::generic("bad form input");
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < bytes.len() {
        let len = u32::from_le_bytes(bytes.get(pos..pos + 4).ok_or_else(bad)?.try_into().unwrap()) as usize;
        pos += 4;
        let s = bytes.get(pos..pos + len).ok_or_else(bad)?;
        out.push(String::from_utf8(s.to_vec()).map_err(|_| bad())?);
        pos += len;
    }
    Ok(out)
}

// ops of `dox_pdf_form`; the same numbers are in form_bindings.dart
pub const GET_FORM: i32 = 0;
pub const HAS_XFA: i32 = 1;
pub const DELETE_XFA: i32 = 2;
pub const GET_FIELDS: i32 = 3;
pub const FIND_FIELD: i32 = 4;
pub const CREATE_FIELD: i32 = 5;
pub const REMOVE_FIELD: i32 = 6;
pub const FLATTEN: i32 = 7;
pub const UPDATE_APPEARANCES: i32 = 8;
pub const DEFAULT_FONT: i32 = 9;
pub const NAME: i32 = 10;
pub const FLAGS: i32 = 11;
pub const SET_FLAG: i32 = 12;
pub const NEEDS_UPDATE: i32 = 13;
pub const MARK_DIRTY: i32 = 14;
pub const MARK_CLEAN: i32 = 15;
pub const IS_DIRTY: i32 = 16;
pub const UPDATE_FIELD: i32 = 17;
pub const TEXT_GET: i32 = 20;
pub const TEXT_SET: i32 = 21;
pub const ALIGNMENT_GET: i32 = 22;
pub const ALIGNMENT_SET: i32 = 23;
pub const MAX_LENGTH_GET: i32 = 24;
pub const MAX_LENGTH_SET: i32 = 25;
pub const FONT_SIZE_SET: i32 = 26;
pub const CHECK: i32 = 30;
pub const UNCHECK: i32 = 31;
pub const IS_CHECKED: i32 = 32;
pub const RADIO_OPTIONS: i32 = 33;
pub const RADIO_SELECTED: i32 = 34;
pub const RADIO_SELECT: i32 = 35;
pub const RADIO_CLEAR: i32 = 36;
pub const CHOICE_OPTIONS: i32 = 40;
pub const CHOICE_SELECTED: i32 = 41;
pub const CHOICE_SET_OPTIONS: i32 = 42;
pub const CHOICE_ADD_OPTIONS: i32 = 43;
pub const CHOICE_SELECT: i32 = 44;
pub const CHOICE_CLEAR: i32 = 45;
pub const ADD_TO_PAGE: i32 = 50;
pub const SET_IMAGE: i32 = 51;
pub const WIDGETS: i32 = 52;
pub const PAGE_OF_ANNOT: i32 = 53;

/// Ops that do not change the document, so its `generation` stays.
fn read_only(op: i32) -> bool {
    matches!(
        op,
        HAS_XFA
            | GET_FIELDS
            | FIND_FIELD
            | NAME
            | FLAGS
            | NEEDS_UPDATE
            | IS_DIRTY
            | TEXT_GET
            | ALIGNMENT_GET
            | MAX_LENGTH_GET
            | IS_CHECKED
            | RADIO_OPTIONS
            | RADIO_SELECTED
            | CHOICE_OPTIONS
            | CHOICE_SELECTED
            | WIDGETS
            | PAGE_OF_ANNOT
    )
}

fn field_kind(pdf: &Document, field: ObjectId) -> Result<i32> {
    kind(pdf, field).ok_or_else(|| Error::generic("the field is gone or is not a form field"))
}

/// One form call. `out[0]` = a number, `out[1]` = a `Bytes` address of
/// the output records (0 when none).
fn form_call(doc: &mut Doc, op: i32, field: ObjectId, n: &[f64], s: &[String], out: &mut [i64; 2]) -> Result<()> {
    let mut o = Out::default();
    let num_at = |i: usize| n.get(i).copied().ok_or_else(|| Error::generic("bad form input"));
    let str_at = |i: usize| {
        s.get(i)
            .map(String::as_str)
            .ok_or_else(|| Error::generic("bad form input"))
    };
    let pdf_has_xfa = |pdf: &Document| {
        acroform_ref(pdf)
            .and_then(|id| dict_of(pdf, id))
            .is_some_and(|d| d.has(b"XFA"))
    };
    match op {
        GET_FORM => {
            acroform(&mut doc.pdf, true)?;
            doc.form.accessed = true;
            let had = pdf_has_xfa(&doc.pdf);
            if had && let Some(id) = acroform_ref(&doc.pdf) {
                dict_mut(&mut doc.pdf, id)?.remove(b"XFA");
            }
            out[0] = had as i64;
        }
        HAS_XFA => out[0] = pdf_has_xfa(&doc.pdf) as i64,
        DELETE_XFA => {
            if let Some(id) = acroform_ref(&doc.pdf) {
                dict_mut(&mut doc.pdf, id)?.remove(b"XFA");
            }
        }
        GET_FIELDS => o.fields(&all_fields(&doc.pdf)),
        FIND_FIELD => {
            let name = str_at(0)?;
            let pdf = &doc.pdf;
            let hit: Vec<_> = all_fields(pdf)
                .into_iter()
                .find(|(id, _)| full_name(pdf, *id) == name)
                .into_iter()
                .collect();
            o.fields(&hit);
        }
        CREATE_FIELD => {
            let kind = num_at(0)? as i32;
            let id = create_field(doc, kind, str_at(0)?)?;
            o.fields(&[(id, kind)]);
        }
        REMOVE_FIELD => {
            let pages = annot_pages(&doc.pdf);
            remove_field_with(doc, field, &pages)?;
        }
        FLATTEN => flatten(doc, num_at(0)? != 0.0)?,
        UPDATE_APPEARANCES => {
            let font = num_at(0)? as i64;
            update_all(doc, (font != 0).then(|| ref_from_i64(font)))?;
        }
        DEFAULT_FONT => out[0] = ref_to_i64(default_font(doc)?),
        NAME => o.str(&full_name(&doc.pdf, field)),
        FLAGS => out[0] = flags(&doc.pdf, field),
        SET_FLAG => {
            set_flag(&mut doc.pdf, field, num_at(0)? as i64, num_at(1)? != 0.0)?;
            if num_at(2)? != 0.0 {
                doc.form.dirty.insert(field);
            }
        }
        NEEDS_UPDATE => out[0] = needs_update(doc, field, field_kind(&doc.pdf, field)?) as i64,
        MARK_DIRTY => {
            doc.form.dirty.insert(field);
        }
        MARK_CLEAN => {
            doc.form.dirty.remove(&field);
        }
        IS_DIRTY => out[0] = doc.form.dirty.contains(&field) as i64,
        UPDATE_FIELD => {
            // `updateAppearances(font)` of one field
            let kind = field_kind(&doc.pdf, field)?;
            let font = match num_at(0)? as i64 {
                0 => default_font(doc)?,
                f => ref_from_i64(f),
            };
            let font = form_font(doc, font)?;
            update_field(doc, field, kind, &font)?;
        }
        TEXT_GET => {
            let value = text_value(&doc.pdf, field);
            if value.is_none() && has_flag(&doc.pdf, field, RICH_TEXT) {
                return Err(form_error(
                    "RichTextFieldReadError",
                    format!(
                        "Reading rich text fields is not supported: Attempted to read rich text field: {}",
                        full_name(&doc.pdf, field)
                    ),
                ));
            }
            o.opt_str(value.as_deref());
        }
        TEXT_SET => {
            let pdf = &mut doc.pdf;
            let text = s.first().filter(|t| !t.is_empty());
            let max = dict_of(pdf, field).and_then(|d| get_num(pdf, d, b"MaxLen"));
            if let (Some(max), Some(t)) = (max, text) {
                let len = t.encode_utf16().count();
                if len as f64 > max {
                    return Err(form_error(
                        "ExceededMaxLengthError",
                        format!(
                            "Attempted to set text with length={len} for TextField with maxLength={} and name={}",
                            js_num(max),
                            full_name(pdf, field)
                        ),
                    ));
                }
            }
            doc.form.dirty.insert(field);
            set_flag(pdf, field, RICH_TEXT, false)?;
            let d = dict_mut(pdf, field)?;
            match text {
                Some(t) => d.set("V", text_object(t)),
                None => {
                    d.remove(b"V");
                }
            }
        }
        ALIGNMENT_GET => {
            let d = dict_of(&doc.pdf, field).cloned().unwrap_or_default();
            out[0] = alignment(&doc.pdf, &d) as i64;
        }
        ALIGNMENT_SET => {
            doc.form.dirty.insert(field);
            dict_mut(&mut doc.pdf, field)?.set("Q", Object::Integer(num_at(0)? as i64));
        }
        MAX_LENGTH_GET => {
            let pdf = &doc.pdf;
            let max = dict_of(pdf, field).and_then(|d| get_num(pdf, d, b"MaxLen"));
            out[0] = max.map(|m| m as i64).unwrap_or(-1);
        }
        MAX_LENGTH_SET => {
            let max = num_at(0)?;
            doc.form.dirty.insert(field);
            let pdf = &mut doc.pdf;
            if max < 0.0 {
                dict_mut(pdf, field)?.remove(b"MaxLen");
            } else {
                let len = text_value(pdf, field).map(|t| t.encode_utf16().count()).unwrap_or(0);
                if len as f64 > max {
                    return Err(form_error(
                        "InvalidMaxLengthError",
                        format!(
                            "Attempted to set maxLength={}, which is less than {len}, the length of this field's current value (name={})",
                            js_num(max),
                            full_name(pdf, field)
                        ),
                    ));
                }
                dict_mut(pdf, field)?.set("MaxLen", num(max));
            }
        }
        FONT_SIZE_SET => {
            set_font_size(&mut doc.pdf, field, num_at(0)?)?;
            doc.form.dirty.insert(field);
        }
        CHECK => {
            let pdf = &mut doc.pdf;
            let on = widgets(pdf, field)
                .first()
                .and_then(|w| on_value(pdf, *w))
                .unwrap_or_else(|| b"Yes".to_vec());
            doc.form.dirty.insert(field);
            set_button_value(pdf, field, &on)?;
        }
        UNCHECK | RADIO_CLEAR => {
            doc.form.dirty.insert(field);
            set_button_value(&mut doc.pdf, field, b"Off")?;
        }
        IS_CHECKED => {
            let pdf = &doc.pdf;
            let on = widgets(pdf, field).first().and_then(|w| on_value(pdf, *w));
            out[0] = on.is_some_and(|on| on == name_value(pdf, field)) as i64;
        }
        RADIO_OPTIONS => o.strs(&radio_options(&doc.pdf, field)),
        RADIO_SELECTED => {
            let pdf = &doc.pdf;
            let value = name_value(pdf, field);
            let selected = if value == b"Off" {
                None
            } else {
                let ons = on_values(pdf, field);
                export_values(pdf, field)
                    .and_then(|ex| ons.iter().position(|v| *v == value).and_then(|i| ex.get(i).cloned()))
                    .or_else(|| Some(name_text(&value)))
            };
            o.opt_str(selected.as_deref());
        }
        RADIO_SELECT => {
            let option = str_at(0)?;
            let pdf = &mut doc.pdf;
            let valid = radio_options(pdf, field);
            if !valid.iter().any(|v| v == option) {
                return Err(Error::generic(format!(
                    "`option` must be one of {}, but was actually \"{option}\"",
                    valid
                        .iter()
                        .map(|v| format!("\"{v}\""))
                        .collect::<Vec<_>>()
                        .join(" or ")
                )));
            }
            doc.form.dirty.insert(field);
            let ons = on_values(pdf, field);
            let pick: Vec<Vec<u8>> = match export_values(pdf, field) {
                Some(ex) => ex
                    .iter()
                    .enumerate()
                    .filter(|(_, v)| *v == option)
                    .filter_map(|(i, _)| ons.get(i).cloned())
                    .collect(),
                None => ons.into_iter().filter(|v| name_text(v) == option).collect(),
            };
            for v in pick {
                set_button_value(pdf, field, &v)?;
            }
        }
        CHOICE_OPTIONS => {
            let d = dict_of(&doc.pdf, field).cloned().unwrap_or_default();
            let list: Vec<String> = choice_options(&doc.pdf, &d).into_iter().map(|o| o.2).collect();
            o.strs(&list);
        }
        CHOICE_SELECTED => o.strs(&shown_values(&doc.pdf, field)),
        CHOICE_SET_OPTIONS | CHOICE_ADD_OPTIONS => {
            let pdf = &mut doc.pdf;
            let mut list: Vec<Object> = Vec::new();
            if op == CHOICE_ADD_OPTIONS {
                let d = dict_of(pdf, field).cloned().unwrap_or_default();
                for (v, d, _) in choice_options(pdf, &d) {
                    list.push(Object::Array(vec![v, d]));
                }
            }
            for v in s {
                list.push(Object::Array(vec![text_object(v), text_object(v)]));
            }
            dict_mut(pdf, field)?.set("Opt", Object::Array(list));
            if num_at(0)? != 0.0 {
                doc.form.dirty.insert(field);
            }
        }
        CHOICE_SELECT => {
            let merge = num_at(0)? != 0.0;
            let pdf = &mut doc.pdf;
            let kind = field_kind(pdf, field)?;
            let pairs = choice_pairs(pdf, field);
            // a display text or an export value; display text first
            let pick = |v: &String| {
                pairs
                    .iter()
                    .find(|p| p.2 == *v)
                    .or_else(|| pairs.iter().find(|p| p.1 == *v))
                    .map(|p| p.0.clone())
            };
            if kind == OPTION_LIST
                && let Some(bad) = s.iter().find(|v| pick(v).is_none())
            {
                return Err(Error::generic(format!(
                    "`option` must be one of {}, but was actually \"{bad}\"",
                    pairs
                        .iter()
                        .map(|p| format!("\"{}\"", p.2))
                        .collect::<Vec<_>>()
                        .join(" or ")
                )));
            }
            if kind == DROPDOWN && s.iter().any(|v| pick(v).is_none()) {
                set_flag(pdf, field, EDIT, true)?;
            }
            doc.form.dirty.insert(field);
            if s.len() > 1 || (s.len() == 1 && merge) {
                set_flag(pdf, field, MULTI_SELECT, true)?;
            }
            let mut values = if merge {
                choice_value_objects(pdf, field)
            } else {
                Vec::new()
            };
            values.extend(s.iter().map(|v| pick(v).unwrap_or_else(|| text_object(v))));
            set_choice_values(pdf, field, values)?;
        }
        CHOICE_CLEAR => {
            doc.form.dirty.insert(field);
            set_choice_values(&mut doc.pdf, field, Vec::new())?;
        }
        ADD_TO_PAGE => {
            let kind = field_kind(&doc.pdf, field)?;
            let text = s.first().map(String::as_str).unwrap_or("");
            out[0] = ref_to_i64(add_to_page(doc, field, kind, n, text)?);
        }
        SET_IMAGE => {
            let image = ref_from_i64(num_at(0)? as i64);
            let alignment = num_at(1)? as i32;
            for w in widgets(&doc.pdf, field) {
                image_appearance(&mut doc.pdf, w, image, alignment)?;
            }
            doc.form.dirty.remove(&field);
        }
        WIDGETS => widget_info(&doc.pdf, field, &mut o),
        PAGE_OF_ANNOT => {
            let pages = annot_pages(&doc.pdf);
            out[0] = pages.1.get(&field).map(|p| ref_to_i64(*p)).unwrap_or(0);
        }
        _ => return Err(Error::generic(format!("unknown form op {op}"))),
    }
    if !o.0.is_empty() {
        out[1] = bytes_into_raw(o.0);
    }
    Ok(())
}

// ------------------------------------------------------------ exports

/// One form call: see `form_call`. `out` has room for 2 values.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_form(
    handle: *const c_void,
    op: i32,
    field: i64,
    nums: *const f64,
    nums_len: i64,
    bytes: *const u8,
    bytes_len: i64,
    out: *mut i64,
) -> i32 {
    call(|| {
        if nums_len < 0 || (nums_len > 0 && nums.is_null()) || out.is_null() {
            return Err(Error::generic("bad input buffer"));
        }
        // SAFETY: Dart passes `nums_len` doubles.
        let n = if nums_len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(nums, nums_len as usize) }
        };
        let s = strings(slice(bytes, bytes_len)?)?;
        let mut result = [0i64; 2];
        let run = |d: &mut Doc| form_call(d, op, ref_from_i64(field), n, &s, &mut result);
        if read_only(op) {
            with_doc(handle, run)?;
        } else {
            with_doc_mut(handle, run)?;
        }
        // SAFETY: Dart passes room for 2 values.
        unsafe {
            *out = result[0];
            *out.add(1) = result[1];
        }
        Ok(OK)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::{create, insert_page, load, new_page, save};

    fn doc_with_page() -> (Doc, ObjectId) {
        let mut d = create(false, b"");
        let p = new_page(&mut d.pdf, 600.0, 800.0);
        insert_page(&mut d.pdf, 0, p).unwrap();
        (d, p)
    }

    fn page_opts(page: ObjectId) -> Vec<f64> {
        let mut n = vec![0.0; at::LEN];
        n[at::PAGE] = ref_to_i64(page) as f64;
        n[at::X] = 10.0;
        n[at::Y] = 20.0;
        n[at::W] = 200.0;
        n[at::H] = 50.0;
        n[at::TEXT_COLOR..at::TEXT_COLOR + 5].copy_from_slice(&[2.0, 0.0, 0.0, 0.0, 0.0]);
        n[at::BG..at::BG + 5].copy_from_slice(&[2.0, 1.0, 1.0, 1.0, 0.0]);
        n[at::BORDER..at::BORDER + 5].copy_from_slice(&[2.0, 0.0, 0.0, 0.0, 0.0]);
        n[at::BORDER_WIDTH] = 1.0;
        n
    }

    #[test]
    fn da_regexes_match_like_pdf_lib() {
        assert_eq!(da_font_size(Some(b"/Helv 12 Tf 0 g")), Some(12.0));
        assert_eq!(da_font_size(Some(b"/HeBo 8.00 Tf")), Some(8.0));
        assert_eq!(da_font_size(Some(b"/A 1 Tf /B 2.5 Tf")), Some(2.5));
        assert_eq!(da_font_size(Some(b"/Helv Tf")), None);
        assert_eq!(da_color(Some(b"/Helv 12 Tf 0 g")), Some(Color::Gray(0.0)));
        assert_eq!(da_color(Some(b"0.3 1 .3 rg")), Some(Color::Rgb(0.3, 1.0, 0.3)));
        assert_eq!(
            da_color(Some(b"1 0 0 0 k /F 3 Tf")),
            Some(Color::Cmyk(1.0, 0.0, 0.0, 0.0))
        );
        assert_eq!(da_color(Some(b"/Helv 12 Tf")), None);
        let (s, e, name, _) = last_tf(b"0 g /Helv 0 Tf x", false).unwrap();
        assert_eq!((s, e, name.as_slice()), (4, 14, &b"Helv"[..]));
        assert!(last_tf(b"/Helv Tf", false).is_some());
        // a long hostile /DA is linear time
        let long = [b"1 ".repeat(50_000), b"rg /F 9 Tf".to_vec()].concat();
        let t = std::time::Instant::now();
        assert_eq!(da_font_size(Some(&long)), Some(9.0));
        assert!(da_color(Some(&long)).is_some());
        assert!(da_color(Some(&b"9".repeat(100_000))).is_none());
        assert!(t.elapsed().as_millis() < 500);
    }

    #[test]
    fn create_fill_and_read_back() {
        let (mut d, page) = doc_with_page();
        let id = create_field(&mut d, TEXT_FIELD, "a.b.name").unwrap();
        assert_eq!(full_name(&d.pdf, id), "a.b.name");
        assert_eq!(
            create_field(&mut d, TEXT_FIELD, "a.b.name").unwrap_err().status,
            ERR_FORM
        );
        add_to_page(&mut d, id, TEXT_FIELD, &page_opts(page), "").unwrap();
        let mut out = [0i64; 2];
        form_call(&mut d, TEXT_SET, id, &[], &["Hello".into()], &mut out).unwrap();
        assert_eq!(text_value(&d.pdf, id).as_deref(), Some("Hello"));
        assert!(needs_update(&d, id, TEXT_FIELD));
        update_all(&mut d, None).unwrap();
        assert!(!needs_update(&d, id, TEXT_FIELD));
        // the default appearance got the font and the size that was used
        let da = own_da(&d.pdf, id).unwrap();
        assert!(
            da.starts_with(b"0 0 0 rg\n/Helvetica "),
            "{}",
            String::from_utf8_lossy(&da)
        );
        let bytes = save(&mut d, 0).unwrap();
        let again = load(&bytes, 0, b"").unwrap();
        let fields = all_fields(&again.pdf);
        assert_eq!(fields.len(), 1);
        assert_eq!(text_value(&again.pdf, fields[0].0).as_deref(), Some("Hello"));
    }

    #[test]
    fn check_box_and_radio_states() {
        let (mut d, page) = doc_with_page();
        let cb = create_field(&mut d, CHECK_BOX, "cb").unwrap();
        add_to_page(&mut d, cb, CHECK_BOX, &page_opts(page), "").unwrap();
        let mut out = [0i64; 2];
        form_call(&mut d, CHECK, cb, &[], &[], &mut out).unwrap();
        form_call(&mut d, IS_CHECKED, cb, &[], &[], &mut out).unwrap();
        assert_eq!(out[0], 1);
        let w = widgets(&d.pdf, cb)[0];
        assert_eq!(appearance_state(&d.pdf, w).unwrap(), b"Yes");

        let rg = create_field(&mut d, RADIO_GROUP, "rg").unwrap();
        add_to_page(&mut d, rg, RADIO_GROUP, &page_opts(page), "dog").unwrap();
        add_to_page(&mut d, rg, RADIO_GROUP, &page_opts(page), "cat").unwrap();
        assert_eq!(radio_options(&d.pdf, rg), vec!["dog", "cat"]);
        form_call(&mut d, RADIO_SELECT, rg, &[], &["cat".into()], &mut out).unwrap();
        assert_eq!(name_value(&d.pdf, rg), b"1");
        assert!(form_call(&mut d, RADIO_SELECT, rg, &[], &["cow".into()], &mut out).is_err());
    }

    #[test]
    fn flatten_draws_and_removes_fields() {
        let (mut d, page) = doc_with_page();
        let id = create_field(&mut d, TEXT_FIELD, "t").unwrap();
        add_to_page(&mut d, id, TEXT_FIELD, &page_opts(page), "").unwrap();
        flatten(&mut d, true).unwrap();
        assert!(all_fields(&d.pdf).is_empty());
        let annots = dict_of(&d.pdf, page).and_then(|p| get(&d.pdf, p, b"Annots")).cloned();
        assert_eq!(annots, Some(Object::Array(vec![])));
        let xobjects = get_dict(
            &d.pdf,
            get_dict(&d.pdf, dict_of(&d.pdf, page).unwrap(), b"Resources").unwrap(),
            b"XObject",
        )
        .unwrap();
        assert!(xobjects.has(b"FlatWidget-1"));
    }

    #[test]
    fn broken_fields_are_skipped() {
        let (mut d, _) = doc_with_page();
        let form = acroform(&mut d.pdf, true).unwrap().unwrap();
        // a field that is not a dict, a loop, and a field with no type
        let mut looped = Dictionary::new();
        looped.set("T", text_object("loop"));
        let lid = d.pdf.add_object(Object::Dictionary(looped));
        let mut child = Dictionary::new();
        child.set("T", text_object("kid"));
        child.set("Parent", Object::Reference(lid));
        child.set("Kids", Object::Array(vec![Object::Reference(lid)]));
        let cid = d.pdf.add_object(Object::Dictionary(child));
        dict_mut(&mut d.pdf, lid)
            .unwrap()
            .set("Kids", Object::Array(vec![Object::Reference(cid)]));
        dict_mut(&mut d.pdf, lid).unwrap().set("Parent", Object::Reference(cid));
        let fields = Object::Array(vec![
            Object::Integer(3),
            Object::Reference((999, 0)),
            Object::Reference(lid),
        ]);
        dict_mut(&mut d.pdf, form).unwrap().set("Fields", fields);
        assert!(all_fields(&d.pdf).is_empty());
        update_all(&mut d, None).unwrap();
        flatten(&mut d, true).unwrap();
        assert!(!full_name(&d.pdf, cid).is_empty());
    }

    #[test]
    fn inherited_values_and_widgets() {
        let (mut d, _) = doc_with_page();
        let form = acroform(&mut d.pdf, true).unwrap().unwrap();
        // a parent with /FT, /Ff, /V and /DA, and a kid field with 2 widgets
        let mut p = Dictionary::new();
        p.set("FT", name("Tx"));
        p.set("V", text_object("from parent"));
        p.set("DA", Object::string_literal("/Helv 9 Tf 0 0 1 rg"));
        let parent_id = d.pdf.add_object(Object::Dictionary(p));
        let mut w1 = Dictionary::new();
        w1.set("Subtype", name("Widget"));
        w1.set("Rect", Object::Array(vec![0.into(), 0.into(), 100.into(), 20.into()]));
        w1.set("Parent", Object::Reference(parent_id));
        let w1 = d.pdf.add_object(Object::Dictionary(w1));
        let w2 = d
            .pdf
            .add_object(Object::Dictionary(dict_of(&d.pdf, w1).unwrap().clone()));
        dict_mut(&mut d.pdf, parent_id).unwrap().set(
            "Kids",
            Object::Array(vec![Object::Reference(w1), Object::Reference(w2)]),
        );
        dict_mut(&mut d.pdf, parent_id).unwrap().set("T", text_object("f"));
        dict_mut(&mut d.pdf, form)
            .unwrap()
            .set("Fields", Object::Array(vec![Object::Reference(parent_id)]));
        assert_eq!(all_fields(&d.pdf), vec![(parent_id, TEXT_FIELD)]);
        assert_eq!(widgets(&d.pdf, parent_id), vec![w1, w2]);
        update_all(&mut d, None).unwrap();
        // the size of the /DA is used, the color too
        let da = own_da(&d.pdf, parent_id).unwrap();
        assert_eq!(da, b"0 0 1 rg\n/Helvetica 9 Tf");
        assert!(matches!(normal(&d.pdf, w2), Some(Object::Stream(_))));
    }

    #[test]
    fn huge_comb_max_len_is_one_line() {
        let (mut d, page) = doc_with_page();
        let id = create_field(&mut d, TEXT_FIELD, "t").unwrap();
        add_to_page(&mut d, id, TEXT_FIELD, &page_opts(page), "").unwrap();
        set_flag(&mut d.pdf, id, COMB, true).unwrap();
        dict_mut(&mut d.pdf, id)
            .unwrap()
            .set("MaxLen", Object::Integer(4_000_000_000_000));
        dict_mut(&mut d.pdf, id).unwrap().set("V", text_object("abc"));
        d.form.dirty.insert(id);
        update_all(&mut d, None).unwrap();
        assert!(!needs_update(&d, id, TEXT_FIELD));
    }

    #[test]
    fn choice_export_and_display_values() {
        let (mut d, page) = doc_with_page();
        let id = create_field(&mut d, DROPDOWN, "c").unwrap();
        let pair = |v: &str, s: &str| Object::Array(vec![text_object(v), text_object(s)]);
        dict_mut(&mut d.pdf, id)
            .unwrap()
            .set("Opt", Object::Array(vec![pair("CA", "Canada"), pair("MM", "Myanmar")]));
        add_to_page(&mut d, id, DROPDOWN, &page_opts(page), "").unwrap();
        let mut out = [0i64; 2];
        form_call(&mut d, CHOICE_SELECT, id, &[0.0], &["Canada".into()], &mut out).unwrap();
        assert_eq!(choice_values(&d.pdf, id), vec!["CA"]);
        assert_eq!(shown_values(&d.pdf, id), vec!["Canada"]);
        // the export value works too, and does not turn on Edit
        form_call(&mut d, CHOICE_SELECT, id, &[0.0], &["MM".into()], &mut out).unwrap();
        assert_eq!(choice_values(&d.pdf, id), vec!["MM"]);
        assert!(!has_flag(&d.pdf, id, EDIT));
        update_all(&mut d, None).unwrap();
    }

    #[test]
    fn multiline_layout_like_pdf_lib() {
        let f = font::font(4).unwrap();
        let b = Bounds {
            x: 2.0,
            y: 2.0,
            w: 100.0,
            h: 200.0,
        };
        let (lines, size, _) = layout_multi("hello world this wraps\r\nnext", 0, Some(12.0), f, b).unwrap();
        let texts: Vec<&str> = lines.iter().map(|l| l.text.as_str()).collect();
        // \r\n is two breaks in pdf-lib, so an empty line
        assert_eq!(texts, vec!["hello world this", "wraps", "", "next"]);
        assert_eq!(size, 12.0);
        // auto size of a single line
        let (_, size) = layout_single("Hi", 0, None, f, b).unwrap();
        assert!(size > 4.0);
    }
}
