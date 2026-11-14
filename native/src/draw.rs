//! Drawing on a page: text, shapes, SVG paths, images and raw operators.
//! The operators are the same as pdf-lib's `operations.ts` writes. Each
//! Dart draw call is one FFI call (`dox_pdf_draw`); the content stream is
//! built here and compressed (FlateDecode) on save, like pdf-lib does.

use std::collections::HashMap;
use std::f64::consts::PI;
use std::ffi::c_void;
use std::io::Write;

use lopdf::{Dictionary, Document, Object, ObjectId, Stream};

use crate::document::{deref, inherited, num, page_dict, page_dict_mut, ref_from_i64};
use crate::ffi_util::*;
use crate::font;
use crate::page;

/// Drawing state of a document. Part of `Doc`, so it is cloned with it.
#[derive(Clone, Default)]
pub struct DrawState {
    /// Embedded standard fonts: font ref -> `StandardFonts` index.
    pub fonts: HashMap<ObjectId, i32>,
    pages: HashMap<ObjectId, PageState>,
    /// The shared `q` and `Q` streams that wrap old page content.
    push_pop: Option<(ObjectId, ObjectId)>,
}

#[derive(Clone, Default)]
struct PageState {
    normalized: bool,
    /// The content stream that draw calls append to.
    content: Option<ObjectId>,
    /// Resource names already added to this page, so a font, image or
    /// graphics state is added once per page, not once per draw call.
    names: HashMap<ResKey, Vec<u8>>,
}

#[derive(Clone, PartialEq, Eq, Hash)]
enum ResKey {
    Font(ObjectId),
    Image(ObjectId),
    /// opacity, border opacity (f64 bits) and blend mode
    Gs(u64, u64, i32),
}

const BLEND_MODES: [&str; 12] = [
    "Normal",
    "Multiply",
    "Screen",
    "Overlay",
    "Darken",
    "Lighten",
    "ColorDodge",
    "ColorBurn",
    "HardLight",
    "SoftLight",
    "Difference",
    "Exclusion",
];

const KAPPA: f64 = 4.0 * ((std::f64::consts::SQRT_2 - 1.0) / 3.0);

// ------------------------------------------------------------ the page

/// Marks a content stream made here, so save compresses it. A copied page
/// keeps the mark, so its copy is compressed too. Save removes the mark
/// from the file it writes.
const PLAIN_MARK: &[u8] = b"DoxPdfLibPlain";

fn new_stream(pdf: &mut Document, content: Vec<u8>) -> ObjectId {
    let mut dict = Dictionary::new();
    dict.set(PLAIN_MARK, Object::Boolean(true));
    pdf.add_object(Object::Stream(Stream::new(dict, content)))
}

/// pdf-lib's `PDFPageLeaf.normalize`: `Contents` becomes an array, old
/// content is wrapped in `q` ... `Q`, and `Resources` with `Font`,
/// `XObject` and `ExtGState` are direct dicts of the page.
///
/// pdf-lib shares an inherited or referenced `Resources` dict (a TODO
/// there); we copy it into the page, so drawing on one page does not
/// change another page.
fn normalize(pdf: &mut Document, state: &mut DrawState, page: ObjectId) -> Result<()> {
    if state.pages.get(&page).is_some_and(|p| p.normalized) {
        return Ok(());
    }
    let dict = page_dict(pdf, page)?;
    let contents = match dict.get(b"Contents").ok() {
        Some(Object::Reference(id)) => match pdf.objects.get(id) {
            Some(Object::Stream(_)) => Some(vec![Object::Reference(*id)]),
            Some(Object::Array(a)) => Some(a.clone()),
            _ => None,
        },
        Some(Object::Array(a)) => Some(a.clone()),
        _ => None,
    };
    let mut resources = match inherited(pdf, dict, b"Resources") {
        Some(Object::Dictionary(d)) => d.clone(),
        _ => Dictionary::new(),
    };
    for key in [&b"Font"[..], b"XObject", b"ExtGState"] {
        let sub = match resources.get(key).ok().and_then(|o| deref(pdf, o)) {
            Some(Object::Dictionary(d)) => d.clone(),
            _ => Dictionary::new(),
        };
        resources.set(key, Object::Dictionary(sub));
    }
    let contents = match contents {
        Some(mut list) => {
            let (push, pop) = match state.push_pop {
                Some(p) => p,
                None => {
                    let p = (new_stream(pdf, b"q\n".to_vec()), new_stream(pdf, b"Q\n".to_vec()));
                    state.push_pop = Some(p);
                    p
                }
            };
            list.insert(0, Object::Reference(push));
            list.push(Object::Reference(pop));
            Some(list)
        }
        None => None,
    };
    let dict = page_dict_mut(pdf, page)?;
    if let Some(list) = contents {
        dict.set("Contents", Object::Array(list));
    }
    dict.set("Resources", Object::Dictionary(resources));
    if !dict.has(b"Annots") {
        dict.set("Annots", Object::Array(vec![]));
    }
    state.pages.entry(page).or_default().normalized = true;
    Ok(())
}

fn contents_mut(pdf: &mut Document, page: ObjectId) -> Result<&mut Vec<Object>> {
    let dict = page_dict_mut(pdf, page)?;
    if !matches!(dict.get(b"Contents"), Ok(Object::Array(_))) {
        dict.set("Contents", Object::Array(vec![]));
    }
    Ok(dict.get_mut(b"Contents")?.as_array_mut()?)
}

/// The content stream of the page, made on first use (pdf-lib's
/// `getContentStream`). `fresh` starts a new one (`resetPosition`).
fn content_stream(pdf: &mut Document, state: &mut DrawState, page: ObjectId, fresh: bool) -> Result<ObjectId> {
    normalize(pdf, state, page)?;
    if !fresh && let Some(id) = state.pages.get(&page).and_then(|p| p.content) {
        return Ok(id);
    }
    let id = new_stream(pdf, Vec::new());
    contents_mut(pdf, page)?.push(Object::Reference(id));
    state.pages.entry(page).or_default().content = Some(id);
    Ok(id)
}

fn append(pdf: &mut Document, state: &mut DrawState, page: ObjectId, ops: &[u8]) -> Result<()> {
    let id = content_stream(pdf, state, page, false)?;
    match pdf.objects.get_mut(&id) {
        Some(Object::Stream(s)) => {
            s.content.extend_from_slice(ops);
            s.dict.set("Length", s.content.len() as i64);
            Ok(())
        }
        _ => Err(Error::generic("the content stream of the page is gone")),
    }
}

/// The name of a resource on the page. A new one is `<tag>-<n>`, like
/// pdf-lib's `uniqueKey` (pdf-lib uses a random number).
fn resource(
    pdf: &mut Document,
    state: &mut DrawState,
    page: ObjectId,
    key: ResKey,
    kind: &[u8],
    tag: &str,
    value: impl FnOnce() -> Object,
) -> Result<Vec<u8>> {
    normalize(pdf, state, page)?;
    if let Some(name) = state.pages.get(&page).and_then(|p| p.names.get(&key)) {
        return Ok(name.clone());
    }
    let dict = page_dict_mut(pdf, page)?
        .get_mut(b"Resources")?
        .as_dict_mut()?
        .get_mut(kind)?
        .as_dict_mut()?;
    let mut n = 1;
    let name = loop {
        let name = format!("{tag}-{n}").into_bytes();
        if !dict.has(&name) {
            break name;
        }
        n += 1;
    };
    dict.set(name.clone(), value());
    state.pages.entry(page).or_default().names.insert(key, name.clone());
    Ok(name)
}

/// pdf-lib's `maybeEmbedGraphicsState`. NaN / -1 mean "not set".
fn graphics_state(
    pdf: &mut Document,
    state: &mut DrawState,
    page: ObjectId,
    opacity: f64,
    border_opacity: f64,
    blend: i32,
) -> Result<Option<Vec<u8>>> {
    let blend_name = usize::try_from(blend).ok().and_then(|i| BLEND_MODES.get(i));
    if opacity.is_nan() && border_opacity.is_nan() && blend_name.is_none() {
        return Ok(None);
    }
    let key = ResKey::Gs(opacity.to_bits(), border_opacity.to_bits(), blend);
    let name = resource(pdf, state, page, key, b"ExtGState", "GS", || {
        let mut gs = Dictionary::new();
        gs.set("Type", Object::Name(b"ExtGState".to_vec()));
        if !opacity.is_nan() {
            gs.set("ca", num(opacity));
        }
        if !border_opacity.is_nan() {
            gs.set("CA", num(border_opacity));
        }
        if let Some(bm) = blend_name {
            gs.set("BM", Object::Name(bm.as_bytes().to_vec()));
        }
        Object::Dictionary(gs)
    })?;
    Ok(Some(name))
}

/// For other areas (eg. `drawPage` in embed.rs): appends `ops` to the one
/// current content stream of the page, after all earlier draw calls.
#[allow(dead_code)]
pub fn append_content(doc: &mut Doc, page: ObjectId, ops: &[u8]) -> Result<()> {
    append(&mut doc.pdf, &mut doc.draw, page, ops)
}

/// For other areas: the page's name for XObject `id`, added once per page.
#[allow(dead_code)]
pub fn xobject_name(doc: &mut Doc, page: ObjectId, id: ObjectId, tag: &str) -> Result<Vec<u8>> {
    resource(
        &mut doc.pdf,
        &mut doc.draw,
        page,
        ResKey::Image(id),
        b"XObject",
        tag,
        || Object::Reference(id),
    )
}

/// For other areas: the page's name for an ExtGState with these values
/// (NaN / -1 mean "not set"), or `None` when none is needed.
#[allow(dead_code)]
pub fn graphics_state_name(
    doc: &mut Doc,
    page: ObjectId,
    opacity: f64,
    border_opacity: f64,
    blend: i32,
) -> Result<Option<Vec<u8>>> {
    graphics_state(&mut doc.pdf, &mut doc.draw, page, opacity, border_opacity, blend)
}

// ------------------------------------------------------------ operators

/// A number as pdf-lib writes it (`numberToString`): shortest form, no
/// exponent, and `-0` is `0`.
pub fn write_num(out: &mut Vec<u8>, v: f64) {
    if v == 0.0 {
        out.push(b'0');
    } else if v.is_nan() {
        out.extend_from_slice(b"NaN");
    } else if v.is_infinite() {
        out.extend_from_slice(if v > 0.0 { b"Infinity" } else { b"-Infinity" });
    } else {
        let _ = write!(out, "{v}");
    }
}

/// Content stream writer: each operator on its own line, like pdf-lib.
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
    fn name_op(&mut self, name: &[u8], args: &[f64], op: &str) {
        self.0.push(b'/');
        self.0.extend_from_slice(name);
        self.0.push(b' ');
        self.op(args, op);
    }
    fn gs(&mut self, name: &Option<Vec<u8>>) {
        if let Some(n) = name {
            self.name_op(n, &[], "gs");
        }
    }
    fn cm(&mut self, m: [f64; 6]) {
        self.op(&m, "cm");
    }
    fn translate(&mut self, x: f64, y: f64) {
        self.cm([1.0, 0.0, 0.0, 1.0, x, y]);
    }
    fn scale(&mut self, x: f64, y: f64) {
        self.cm([x, 0.0, 0.0, y, 0.0, 0.0]);
    }
    fn rotate(&mut self, a: f64) {
        self.cm([a.cos(), a.sin(), -a.sin(), a.cos(), 0.0, 0.0]);
    }
    fn skew(&mut self, x: f64, y: f64) {
        self.cm([1.0, x.tan(), y.tan(), 1.0, 0.0, 0.0]);
    }
    /// `c` is `[type, c1, c2, c3, c4]`: 0 none, 1 gray, 2 RGB, 3 CMYK.
    fn color(&mut self, c: &[f64], stroke: bool) {
        let (n, op) = match (c[0] as i32, stroke) {
            (1, false) => (1, "g"),
            (2, false) => (3, "rg"),
            (3, false) => (4, "k"),
            (1, true) => (1, "G"),
            (2, true) => (3, "RG"),
            (3, true) => (4, "K"),
            _ => return,
        };
        self.op(&c[1..1 + n], op);
    }
    fn line_cap(&mut self, cap: f64) {
        // pdf-lib skips a falsy cap, so Butt (0) writes nothing
        if truthy(cap) {
            self.op(&[cap], "J");
        }
    }
    fn dash(&mut self, dashes: &[f64], phase: f64) {
        self.0.push(b'[');
        for (i, d) in dashes.iter().enumerate() {
            if i > 0 {
                self.0.push(b' ');
            }
            write_num(&mut self.0, *d);
        }
        self.0.extend_from_slice(b"] ");
        self.op(&[phase], "d");
    }
    /// The paint operator of rectangle, ellipse and SVG path.
    fn paint(&mut self, fill: bool, stroke: bool, border_width: f64) {
        let op = if fill && truthy(border_width) {
            "B"
        } else if fill {
            "f"
        } else if stroke {
            "S"
        } else {
            "h"
        };
        self.op(&[], op);
    }
}

/// JavaScript truthiness of a number.
fn truthy(v: f64) -> bool {
    v != 0.0 && !v.is_nan()
}

// ------------------------------------------------------------ text layout

fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\x0c' | '\r' | '\x0b')
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

/// The words of pdf-lib's `breakTextIntoLines` regex:
/// `(\n|\f|\r|\u000B)|((.*?)($|<break>|...))` with the `gm` flags.
fn words(text: &[char], breaks: &[Vec<char>]) -> Vec<String> {
    // line terminators: where `$` matches and `.` does not
    let terminator = |c: char| matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}');
    let mut out = Vec::new();
    let mut start = 0;
    while start <= text.len() {
        if start < text.len() && is_newline(text[start]) {
            out.push(text[start].to_string());
            start += 1;
            continue;
        }
        let mut p = start;
        let end = loop {
            if p == text.len() || terminator(text[p]) {
                break p;
            }
            let hit = breaks.iter().find_map(|b| {
                if b.is_empty() {
                    Some(p + 1) // '' is `.`: any char but a terminator
                } else if text[p..].starts_with(b) {
                    Some(p + b.len())
                } else {
                    None
                }
            });
            if let Some(end) = hit {
                break end;
            }
            p += 1;
        };
        out.push(text[start..end].iter().collect());
        // an empty match moves on by one, like a global JS regex
        start = if end == start { end + 1 } else { end };
    }
    out
}

/// pdf-lib's `breakTextIntoLines`.
fn break_lines(text: &str, breaks: &[Vec<char>], max_width: f64, f: &font::Font, size: f64) -> Result<Vec<String>> {
    let chars: Vec<char> = clean_text(text).chars().collect();
    let mut lines = Vec::new();
    let mut line = String::new();
    let mut width = 0.0;
    for word in words(&chars, breaks) {
        if word.chars().count() == 1 && word.chars().all(is_newline) {
            if !line.is_empty() {
                lines.push(std::mem::take(&mut line));
            }
            width = 0.0;
        } else {
            let w = f.width_of_text(&word, size)?;
            if width + w > max_width {
                if !line.is_empty() {
                    lines.push(std::mem::take(&mut line));
                }
                width = 0.0;
            }
            line.push_str(&word);
            width += w;
        }
    }
    if !line.is_empty() {
        lines.push(line);
    }
    Ok(lines)
}

// ------------------------------------------------------------ SVG path

/// pdf-lib's `svgPathToOperators` (from pdfkit), with the same quirks.
///
/// One difference: a command with too few numbers (eg. `M 1 2 L`) is an
/// error here. pdf-lib throws for most of them too, but writes `NaN` for
/// some (relative commands) and nothing for an arc.
fn svg_path(path: &str, out: &mut Ops) -> Result<()> {
    Svg::default().apply(&parse_svg(path), out)
}

fn svg_params(c: char) -> Option<usize> {
    Some(match c {
        'A' | 'a' => 7,
        'C' | 'c' => 6,
        'H' | 'h' | 'V' | 'v' => 1,
        'L' | 'l' | 'M' | 'm' | 'T' | 't' => 2,
        'Q' | 'q' | 'S' | 's' => 4,
        'Z' | 'z' => 0,
        _ => return None,
    })
}

/// JavaScript's `Number(text)` for the texts the parser makes.
fn js_number(text: &str) -> f64 {
    let t = text.trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}');
    if t.is_empty() {
        return 0.0;
    }
    match t.strip_prefix(['+', '-']).unwrap_or(t) {
        "Infinity" => {
            return if t.starts_with('-') {
                f64::NEG_INFINITY
            } else {
                f64::INFINITY
            };
        }
        body if !body
            .bytes()
            .all(|b| b.is_ascii_digit() || matches!(b, b'.' | b'e' | b'E' | b'+' | b'-')) =>
        {
            return f64::NAN;
        }
        _ => {}
    }
    t.parse().unwrap_or(f64::NAN)
}

type SvgCmd = (Option<char>, Vec<f64>);

fn parse_svg(path: &str) -> Vec<SvgCmd> {
    let mut cmd: Option<char> = None;
    let mut ret: Vec<SvgCmd> = Vec::new();
    let mut args: Vec<f64> = Vec::new();
    let mut cur = String::new();
    let mut found_decimal = false;
    let mut params = 0;
    // a full arg list: a repeated command starts (M becomes L, m becomes l)
    let push_arg = |cmd: &mut Option<char>, ret: &mut Vec<SvgCmd>, args: &mut Vec<f64>, v: f64, params: usize| {
        if args.len() == params {
            ret.push((*cmd, std::mem::replace(args, vec![v])));
            match *cmd {
                Some('M') => *cmd = Some('L'),
                Some('m') => *cmd = Some('l'),
                _ => {}
            }
        } else {
            args.push(v);
        }
    };
    for c in path.chars() {
        if let Some(p) = svg_params(c) {
            params = p;
            if cmd.is_some() {
                if !cur.is_empty() {
                    args.push(js_number(&cur));
                }
                ret.push((cmd, std::mem::take(&mut args)));
                cur.clear();
                found_decimal = false;
            }
            cmd = Some(c);
        } else if c == ' '
            || c == ','
            || (c == '-' && !cur.is_empty() && !cur.ends_with('e'))
            || (c == '.' && found_decimal)
        {
            if cur.is_empty() {
                continue;
            }
            push_arg(&mut cmd, &mut ret, &mut args, js_number(&cur), params);
            found_decimal = c == '.';
            cur = if c == '-' || c == '.' {
                c.to_string()
            } else {
                String::new()
            };
        } else {
            cur.push(c);
            if c == '.' {
                found_decimal = true;
            }
        }
    }
    if !cur.is_empty() {
        push_arg(&mut cmd, &mut ret, &mut args, js_number(&cur), params);
    }
    ret.push((cmd, args));
    ret
}

#[derive(Default)]
struct Svg {
    cx: f64,
    cy: f64,
    /// `None` is JavaScript's `null`
    px: Option<f64>,
    py: Option<f64>,
    sx: f64,
    sy: f64,
}

impl Svg {
    fn apply(&mut self, cmds: &[SvgCmd], out: &mut Ops) -> Result<()> {
        self.px = Some(0.0);
        self.py = Some(0.0);
        for (cmd, args) in cmds {
            let Some(cmd) = cmd else { continue };
            let needed = svg_params(*cmd).unwrap_or(0);
            if args.len() < needed {
                return Err(Error::generic(format!(
                    "Invalid SVG path: `{cmd}` needs {needed} numbers, but has {}",
                    args.len()
                )));
            }
            // a text that is not a number is NaN, like in pdf-lib
            let a = |i: usize| args.get(i).copied().unwrap_or(f64::NAN);
            match cmd {
                'M' | 'm' => {
                    if *cmd == 'M' {
                        (self.cx, self.cy) = (a(0), a(1));
                    } else {
                        self.cx += a(0);
                        self.cy += a(1);
                    }
                    (self.px, self.py) = (None, None);
                    (self.sx, self.sy) = (self.cx, self.cy);
                    out.op(&[self.cx, self.cy], "m");
                }
                'C' => {
                    (self.cx, self.cy) = (a(4), a(5));
                    (self.px, self.py) = (Some(a(2)), Some(a(3)));
                    out.op(&[a(0), a(1), a(2), a(3), a(4), a(5)], "c");
                }
                'c' => {
                    let (cx, cy) = (self.cx, self.cy);
                    out.op(&[a(0) + cx, a(1) + cy, a(2) + cx, a(3) + cy, a(4) + cx, a(5) + cy], "c");
                    (self.px, self.py) = (Some(cx + a(2)), Some(cy + a(3)));
                    self.cx += a(4);
                    self.cy += a(5);
                }
                'S' | 's' => {
                    let (cx, cy) = (self.cx, self.cy);
                    let (px, py) = match (self.px, self.py) {
                        (Some(px), Some(py)) => (px, py),
                        _ => (cx, cy),
                    };
                    let (ox, oy) = if *cmd == 'S' { (0.0, 0.0) } else { (cx, cy) };
                    out.op(
                        &[
                            cx - (px - cx),
                            cy - (py - cy),
                            ox + a(0),
                            oy + a(1),
                            ox + a(2),
                            oy + a(3),
                        ],
                        "c",
                    );
                    (self.px, self.py) = (Some(ox + a(0)), Some(oy + a(1)));
                    if *cmd == 'S' {
                        (self.cx, self.cy) = (a(2), a(3));
                    } else {
                        self.cx += a(2);
                        self.cy += a(3);
                    }
                }
                'Q' => {
                    (self.px, self.py) = (Some(a(0)), Some(a(1)));
                    (self.cx, self.cy) = (a(2), a(3));
                    out.op(&[a(0), a(1), self.cx, self.cy], "v");
                }
                'q' => {
                    let (cx, cy) = (self.cx, self.cy);
                    out.op(&[a(0) + cx, a(1) + cy, a(2) + cx, a(3) + cy], "v");
                    (self.px, self.py) = (Some(cx + a(0)), Some(cy + a(1)));
                    self.cx += a(2);
                    self.cy += a(3);
                }
                'T' | 't' => {
                    let (cx, cy) = (self.cx, self.cy);
                    let (px, py) = match (self.px, self.py) {
                        (Some(px), Some(py)) => (cx - (px - cx), cy - (py - cy)),
                        _ => (cx, cy),
                    };
                    if *cmd == 'T' {
                        out.op(&[px, py, a(0), a(1)], "v");
                        // pdf-lib reflects the point again here
                        (self.px, self.py) = (Some(cx - (px - cx)), Some(cy - (py - cy)));
                        (self.cx, self.cy) = (a(0), a(1));
                    } else {
                        out.op(&[px, py, cx + a(0), cy + a(1)], "v");
                        (self.px, self.py) = (Some(px), Some(py));
                        self.cx += a(0);
                        self.cy += a(1);
                    }
                }
                'A' | 'a' => {
                    let mut a: Vec<f64> = (0..7).map(a).collect();
                    if *cmd == 'a' {
                        a[5] += self.cx;
                        a[6] += self.cy;
                    }
                    self.arc(&a, out);
                    (self.cx, self.cy) = (a[5], a[6]);
                }
                'L' | 'l' | 'H' | 'h' | 'V' | 'v' => {
                    match cmd {
                        'L' => (self.cx, self.cy) = (a(0), a(1)),
                        'l' => {
                            self.cx += a(0);
                            self.cy += a(1);
                        }
                        'H' => self.cx = a(0),
                        'h' => self.cx += a(0),
                        'V' => self.cy = a(0),
                        _ => self.cy += a(0),
                    }
                    (self.px, self.py) = (None, None);
                    out.op(&[self.cx, self.cy], "l");
                }
                'Z' | 'z' => {
                    out.op(&[], "h");
                    (self.cx, self.cy) = (self.sx, self.sy);
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// pdf-lib's `solveArc` + `arcToSegments` + `segmentToBezier` (from
    /// Inkscape). Like pdf-lib, it leaves `px`/`py` set.
    fn arc(&mut self, coords: &[f64], out: &mut Ops) {
        let [rx, ry, rot, large, sweep, x, y] = coords[..7] else {
            return;
        };
        let (ox, oy) = (self.cx, self.cy);
        let th = rot * (PI / 180.0);
        let (sin_th, cos_th) = (th.sin(), th.cos());
        let (mut rx, mut ry) = (rx.abs(), ry.abs());
        let px = cos_th * (ox - x) * 0.5 + sin_th * (oy - y) * 0.5;
        let py = cos_th * (oy - y) * 0.5 - sin_th * (ox - x) * 0.5;
        (self.px, self.py) = (Some(px), Some(py));
        let mut pl = (px * px) / (rx * rx) + (py * py) / (ry * ry);
        if pl > 1.0 {
            pl = pl.sqrt();
            rx *= pl;
            ry *= pl;
        }
        let a00 = cos_th / rx;
        let a01 = sin_th / rx;
        let a10 = -sin_th / ry;
        let a11 = cos_th / ry;
        let x0 = a00 * ox + a01 * oy;
        let y0 = a10 * ox + a11 * oy;
        let x1 = a00 * x + a01 * y;
        let y1 = a10 * x + a11 * y;
        let d = (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0);
        let mut sfactor_sq = 1.0 / d - 0.25;
        if sfactor_sq < 0.0 {
            sfactor_sq = 0.0;
        }
        let mut sfactor = sfactor_sq.sqrt();
        if sweep == large {
            sfactor = -sfactor;
        }
        let xc = 0.5 * (x0 + x1) - sfactor * (y1 - y0);
        let yc = 0.5 * (y0 + y1) + sfactor * (x1 - x0);
        let th0 = (y0 - yc).atan2(x0 - xc);
        let th1 = (y1 - yc).atan2(x1 - xc);
        let mut th_arc = th1 - th0;
        if th_arc < 0.0 && sweep == 1.0 {
            th_arc += 2.0 * PI;
        } else if th_arc > 0.0 && sweep == 0.0 {
            th_arc -= 2.0 * PI;
        }
        let segments = (th_arc / (PI * 0.5 + 0.001)).abs().ceil();
        // a NaN or huge count is a broken path; pdf-lib would loop forever
        if !(0.0..=1e6).contains(&segments) {
            return;
        }
        let segments = segments as usize;
        for i in 0..segments {
            let th2 = th0 + (i as f64 * th_arc) / segments as f64;
            let th3 = th0 + ((i + 1) as f64 * th_arc) / segments as f64;
            out.op(&segment_to_bezier(xc, yc, th2, th3, rx, ry, sin_th, cos_th), "c");
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn segment_to_bezier(cx: f64, cy: f64, th0: f64, th1: f64, rx: f64, ry: f64, sin_th: f64, cos_th: f64) -> [f64; 6] {
    let a00 = cos_th * rx;
    let a01 = -sin_th * ry;
    let a10 = sin_th * rx;
    let a11 = cos_th * ry;
    let th_half = 0.5 * (th1 - th0);
    let t = ((8.0 / 3.0) * (th_half * 0.5).sin() * (th_half * 0.5).sin()) / th_half.sin();
    let x1 = cx + th0.cos() - t * th0.sin();
    let y1 = cy + th0.sin() + t * th0.cos();
    let x3 = cx + th1.cos();
    let y3 = cy + th1.sin();
    let x2 = x3 + t * th1.sin();
    let y2 = y3 - t * th1.cos();
    [
        a00 * x1 + a01 * y1,
        a10 * x1 + a11 * y1,
        a00 * x2 + a01 * y2,
        a10 * x2 + a11 * y2,
        a00 * x3 + a01 * y3,
        a10 * x3 + a11 * y3,
    ]
}

// ------------------------------------------------------------ draw calls

/// Kinds of `dox_pdf_draw`. The same numbers are in draw_bindings.dart.
pub const TEXT: i32 = 0;
pub const IMAGE: i32 = 1;
pub const LINE: i32 = 2;
pub const RECTANGLE: i32 = 3;
pub const ELLIPSE: i32 = 4;
pub const SVG: i32 = 5;
pub const OPERATORS: i32 = 6;

/// Every kind starts with: opacity, border opacity, blend mode, the color
/// (5 numbers) and the border color (5 numbers). NaN / -1 / type 0 mean
/// "not set". The numbers of the kind follow at `ARGS`.
const ARGS: usize = 13;

struct Input<'a> {
    nums: &'a [f64],
}

impl Input<'_> {
    fn at(&self, i: usize) -> Result<f64> {
        self.nums
            .get(i)
            .copied()
            .ok_or_else(|| Error::generic("bad draw input"))
    }
    fn color(&self) -> &[f64] {
        &self.nums[3..8]
    }
    fn border_color(&self) -> &[f64] {
        &self.nums[8..13]
    }
    /// The dash array: a count at `i`, then the values.
    fn dashes(&self, i: usize) -> Result<&[f64]> {
        let n = self.at(i)? as usize;
        self.nums
            .get(i + 1..i + 1 + n)
            .ok_or_else(|| Error::generic("bad draw input"))
    }
}

fn has(color: &[f64]) -> bool {
    color[0] as i32 != 0
}

/// One draw call: builds the operators and appends them to the page.
pub fn draw(doc: &mut Doc, page: ObjectId, kind: i32, nums: &[f64], bytes: &[u8]) -> Result<()> {
    if kind == OPERATORS {
        return append(&mut doc.pdf, &mut doc.draw, page, bytes);
    }
    if nums.len() < ARGS {
        return Err(Error::generic("bad draw input"));
    }
    let pdf = &mut doc.pdf;
    let state = &mut doc.draw;
    let input = Input { nums };
    let gs = graphics_state(pdf, state, page, nums[0], nums[1], nums[2] as i32)?;
    let mut o = Ops::default();
    let a = |i: usize| input.at(ARGS + i);
    match kind {
        TEXT => {
            let font_ref = ref_from_i64(a(0)? as i64);
            let font_id = *state
                .fonts
                .get(&font_ref)
                .ok_or_else(|| Error::generic("the font is not embedded in this document"))?;
            let f = font::font(font_id)?;
            let size = a(1)?;
            let text_len = (a(9)? as usize).min(bytes.len());
            let text = std::str::from_utf8(&bytes[..text_len]).map_err(|_| Error::generic("text is not UTF-8"))?;
            let max_width = a(8)?;
            let lines = if max_width.is_nan() {
                clean_text(text).split(is_newline).map(str::to_string).collect()
            } else {
                // word breaks: each one ends with a 0 byte
                let breaks: Vec<Vec<char>> = bytes[text_len..]
                    .split(|b| *b == 0)
                    .collect::<Vec<_>>()
                    .split_last()
                    .map(|(_, all)| all)
                    .unwrap_or(&[])
                    .iter()
                    .map(|b| String::from_utf8_lossy(b).chars().collect())
                    .collect();
                break_lines(text, &breaks, max_width, f, size)?
            };
            let encoded = lines.iter().map(|l| f.glyphs(l)).collect::<Result<Vec<_>>>()?;
            let font_name = resource(pdf, state, page, ResKey::Font(font_ref), b"Font", &f.name, || {
                Object::Reference(font_ref)
            })?;
            let (rot, xskew, yskew) = (a(2)?, a(3)?, a(4)?);
            o.op(&[], "q");
            o.gs(&gs);
            o.op(&[], "BT");
            o.color(input.color(), false);
            o.name_op(&font_name, &[size], "Tf");
            o.op(&[a(7)?], "TL");
            o.op(
                &[
                    rot.cos(),
                    rot.sin() + xskew.tan(),
                    -rot.sin() + yskew.tan(),
                    rot.cos(),
                    a(5)?,
                    a(6)?,
                ],
                "Tm",
            );
            for glyphs in encoded {
                o.0.push(b'<');
                for (code, _) in glyphs {
                    let _ = write!(o.0, "{code:02X}");
                }
                o.0.extend_from_slice(b"> Tj\nT*\n");
            }
            o.op(&[], "ET");
            o.op(&[], "Q");
        }
        IMAGE => {
            let image = ref_from_i64(a(0)? as i64);
            if !matches!(pdf.objects.get(&image), Some(Object::Stream(_))) {
                return Err(Error::generic("the image is not embedded in this document"));
            }
            let name = resource(pdf, state, page, ResKey::Image(image), b"XObject", "Image", || {
                Object::Reference(image)
            })?;
            o.op(&[], "q");
            o.gs(&gs);
            o.translate(a(1)?, a(2)?);
            o.rotate(a(5)?);
            o.scale(a(3)?, a(4)?);
            o.skew(a(6)?, a(7)?);
            o.name_op(&name, &[], "Do");
            o.op(&[], "Q");
        }
        LINE => {
            let (sx, sy) = (a(0)?, a(1)?);
            o.op(&[], "q");
            o.gs(&gs);
            o.color(input.color(), true);
            o.op(&[a(4)?], "w");
            o.dash(input.dashes(ARGS + 7)?, a(5)?);
            o.op(&[sx, sy], "m");
            o.line_cap(a(6)?);
            o.op(&[sx, sy], "m");
            o.op(&[a(2)?, a(3)?], "l");
            o.op(&[], "S");
            o.op(&[], "Q");
        }
        RECTANGLE => {
            let (w, h, border) = (a(2)?, a(3)?, a(7)?);
            o.op(&[], "q");
            o.gs(&gs);
            o.color(input.color(), false);
            o.color(input.border_color(), true);
            o.op(&[border], "w");
            o.line_cap(a(8)?);
            o.dash(input.dashes(ARGS + 10)?, a(9)?);
            o.translate(a(0)?, a(1)?);
            o.rotate(a(4)?);
            o.skew(a(5)?, a(6)?);
            o.op(&[0.0, 0.0], "m");
            o.op(&[0.0, h], "l");
            o.op(&[w, h], "l");
            o.op(&[w, 0.0], "l");
            o.op(&[], "h");
            o.paint(has(input.color()), has(input.border_color()), border);
            o.op(&[], "Q");
        }
        ELLIPSE => {
            let (x, y, xs, ys, rot, border) = (a(0)?, a(1)?, a(2)?, a(3)?, a(4)?, a(5)?);
            o.op(&[], "q");
            o.gs(&gs);
            o.color(input.color(), false);
            o.color(input.border_color(), true);
            o.op(&[border], "w");
            o.line_cap(a(6)?);
            o.dash(input.dashes(ARGS + 8)?, a(7)?);
            let ox = xs * KAPPA;
            let oy = ys * KAPPA;
            // no rotate: pdf-lib's old `drawEllipsePath`, with its own q/Q
            let (bx, by) = if rot.is_nan() { (x - xs, y - ys) } else { (-xs, -ys) };
            if rot.is_nan() {
                o.op(&[], "q");
            } else {
                o.translate(x, y);
                o.rotate(rot);
            }
            let (xe, ye, xm, ym) = (bx + xs * 2.0, by + ys * 2.0, bx + xs, by + ys);
            o.op(&[bx, ym], "m");
            o.op(&[bx, ym - oy, xm - ox, by, xm, by], "c");
            o.op(&[xm + ox, by, xe, ym - oy, xe, ym], "c");
            o.op(&[xe, ym + oy, xm + ox, ye, xm, ye], "c");
            o.op(&[xm - ox, ye, bx, ym + oy, bx, ym], "c");
            if rot.is_nan() {
                o.op(&[], "Q");
            }
            o.paint(has(input.color()), has(input.border_color()), border);
            o.op(&[], "Q");
        }
        SVG => {
            let path = std::str::from_utf8(bytes).map_err(|_| Error::generic("path is not UTF-8"))?;
            let (scale, border) = (a(2)?, a(4)?);
            o.op(&[], "q");
            o.gs(&gs);
            o.translate(a(0)?, a(1)?);
            o.rotate(a(3)?);
            // SVG's y axis points down
            if truthy(scale) {
                o.scale(scale, -scale);
            } else {
                o.scale(1.0, -1.0);
            }
            o.color(input.color(), false);
            o.color(input.border_color(), true);
            if truthy(border) {
                o.op(&[border], "w");
            }
            o.line_cap(a(5)?);
            o.dash(input.dashes(ARGS + 7)?, a(6)?);
            svg_path(path, &mut o)?;
            o.paint(has(input.color()), has(input.border_color()), border);
            o.op(&[], "Q");
        }
        _ => return Err(Error::generic(format!("unknown draw kind {kind}"))),
    }
    append(pdf, state, page, &o.0)
}

// ------------------------------------------------------------ page changes

pub const TRANSLATE_CONTENT: i32 = 0;
pub const SCALE_CONTENT: i32 = 1;
pub const SCALE: i32 = 2;
pub const RESET_POSITION: i32 = 3;
pub const SCALE_ANNOTATIONS: i32 = 4;

/// pdf-lib's `translateContent` / `scaleContent`: all content so far goes
/// into `q <cm>` ... `Q`.
fn wrap_content(pdf: &mut Document, state: &mut DrawState, page: ObjectId, cm: [f64; 6]) -> Result<()> {
    content_stream(pdf, state, page, false)?;
    let mut o = Ops::default();
    o.op(&[], "q");
    o.cm(cm);
    let start = new_stream(pdf, o.0);
    let end = new_stream(pdf, b"Q\n".to_vec());
    let list = contents_mut(pdf, page)?;
    list.insert(0, Object::Reference(start));
    list.push(Object::Reference(end));
    Ok(())
}

/// pdf-lib's `scaleAnnotations`.
fn scale_annotations(pdf: &mut Document, page: ObjectId, x: f64, y: f64) -> Result<()> {
    let dict = page_dict(pdf, page)?;
    let Some(Object::Array(annots)) = dict.get(b"Annots").ok().and_then(|a| deref(pdf, a)) else {
        return Ok(());
    };
    let annots: Vec<Object> = annots.clone();
    let annots_ref = match dict.get(b"Annots") {
        Ok(Object::Reference(id)) => Some(*id),
        _ => None,
    };
    let mut scaled = Vec::with_capacity(annots.len());
    for annot in annots {
        match annot {
            Object::Reference(id) => {
                if let Some(Object::Dictionary(d)) = pdf.objects.get(&id) {
                    let mut d = d.clone();
                    scale_annot(pdf, &mut d, x, y);
                    pdf.objects.insert(id, Object::Dictionary(d));
                }
                scaled.push(Object::Reference(id));
            }
            Object::Dictionary(mut d) => {
                scale_annot(pdf, &mut d, x, y);
                scaled.push(Object::Dictionary(d));
            }
            other => scaled.push(other),
        }
    }
    match annots_ref {
        Some(id) => {
            pdf.objects.insert(id, Object::Array(scaled));
        }
        None => page_dict_mut(pdf, page)?.set("Annots", Object::Array(scaled)),
    }
    Ok(())
}

fn scale_numbers(pdf: &Document, list: &Object, x: f64, y: f64) -> Option<Object> {
    let Object::Array(items) = deref(pdf, list)? else {
        return None;
    };
    let items = items
        .iter()
        .enumerate()
        .map(|(i, item)| match crate::document::as_f64(item) {
            Some(v) => num(v * if i % 2 == 0 { x } else { y }),
            None => item.clone(),
        })
        .collect();
    Some(Object::Array(items))
}

fn scale_annot(pdf: &Document, annot: &mut Dictionary, x: f64, y: f64) {
    for key in [&b"RD"[..], b"CL", b"Vertices", b"QuadPoints", b"L", b"Rect"] {
        if let Some(list) = annot.get(key).ok().and_then(|l| scale_numbers(pdf, l, x, y)) {
            annot.set(key, list);
        }
    }
    let ink = match annot.get(b"InkList").ok().and_then(|l| deref(pdf, l)) {
        Some(Object::Array(lists)) => lists
            .iter()
            .map(|l| scale_numbers(pdf, l, x, y).unwrap_or_else(|| l.clone()))
            .collect(),
        _ => return,
    };
    annot.set("InkList", Object::Array(ink));
}

pub fn change_page(doc: &mut Doc, page: ObjectId, kind: i32, x: f64, y: f64) -> Result<()> {
    let pdf = &mut doc.pdf;
    let state = &mut doc.draw;
    match kind {
        TRANSLATE_CONTENT => wrap_content(pdf, state, page, [1.0, 0.0, 0.0, 1.0, x, y]),
        SCALE_CONTENT => wrap_content(pdf, state, page, [x, 0.0, 0.0, y, 0.0, 0.0]),
        SCALE => {
            let media = page::get_box(pdf, page, page::MEDIA)?;
            page::set_size(pdf, page, media[2] * x, media[3] * y, 0)?;
            wrap_content(pdf, state, page, [x, 0.0, 0.0, y, 0.0, 0.0])?;
            scale_annotations(pdf, page, x, y)
        }
        RESET_POSITION => content_stream(pdf, state, page, true).map(|_| ()),
        SCALE_ANNOTATIONS => scale_annotations(pdf, page, x, y),
        _ => Err(Error::generic(format!("unknown page change {kind}"))),
    }
}

// ------------------------------------------------------------ save

/// Compresses (FlateDecode) the content streams made by draw calls (and
/// their copies), like pdf-lib writes its content streams. Other plain
/// streams stay as they are, like in pdf-lib. Save runs it on the copy it
/// writes, without the lock; the document keeps the streams plain, so
/// later draw calls can append to them.
pub fn flate_page_contents(pdf: &mut Document) -> Result<()> {
    for obj in pdf.objects.values_mut() {
        if let Object::Stream(s) = obj
            && s.dict.remove(PLAIN_MARK).is_some()
            && !s.dict.has(b"Filter")
        {
            let packed = deflate(&s.content)?;
            s.set_content(packed);
            s.dict.set("Filter", Object::Name(b"FlateDecode".to_vec()));
        }
    }
    Ok(())
}

pub fn deflate(data: &[u8]) -> Result<Vec<u8>> {
    let mut e =
        flate2::write::ZlibEncoder::new(Vec::with_capacity(data.len() / 2 + 16), flate2::Compression::default());
    e.write_all(data)?;
    Ok(e.finish()?)
}

// ------------------------------------------------------------ exports

/// One draw call. `nums` and `bytes` as described at `ARGS` and in
/// draw_bindings.dart.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_draw(
    handle: *const c_void,
    page: i64,
    kind: i32,
    nums: *const f64,
    nums_len: i64,
    bytes: *const u8,
    bytes_len: i64,
) -> i32 {
    call(|| {
        if nums_len < 0 || (nums_len > 0 && nums.is_null()) {
            return Err(Error::generic("bad input buffer"));
        }
        let nums = if nums_len == 0 {
            &[][..]
        } else {
            // SAFETY: Dart passes `nums_len` doubles that live for the call.
            unsafe { std::slice::from_raw_parts(nums, nums_len as usize) }
        };
        let bytes = slice(bytes, bytes_len)?;
        with_doc(handle, |d| draw(d, ref_from_i64(page), kind, nums, bytes).map(|_| OK))
    })
}

/// `translateContent`, `scaleContent`, `scale`, `resetPosition` and
/// `scaleAnnotations`.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_page_change(handle: *const c_void, page: i64, kind: i32, x: f64, y: f64) -> i32 {
    call(|| with_doc(handle, |d| change_page(d, ref_from_i64(page), kind, x, y).map(|_| OK)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::{create, insert_page, new_page};

    fn ops(f: impl FnOnce(&mut Ops)) -> String {
        let mut o = Ops::default();
        f(&mut o);
        String::from_utf8(o.0).unwrap()
    }

    fn svg(path: &str) -> Result<String> {
        let mut o = Ops::default();
        svg_path(path, &mut o)?;
        Ok(String::from_utf8(o.0).unwrap())
    }

    #[test]
    fn numbers_like_pdf_lib() {
        let s = |v: f64| {
            let mut out = Vec::new();
            write_num(&mut out, v);
            String::from_utf8(out).unwrap()
        };
        assert_eq!(s(1.0), "1");
        assert_eq!(s(-0.0), "0");
        assert_eq!(s(0.1 + 0.2), "0.30000000000000004");
        assert_eq!(s(1e21), "1000000000000000000000");
        assert_eq!(s(-2.5), "-2.5");
    }

    #[test]
    fn svg_missing_numbers_are_an_error() {
        // pdf-lib 1.17.1 throws for these too
        for path in ["M 1 2 L", "M", "M1,2,,3", "M 1 2 3", "M1E-3 2", "M1.2.3.4"] {
            assert!(svg(path).unwrap_err().message.contains("Invalid SVG path"), "{path}");
        }
        // outputs of pdf-lib 1.17.1
        assert_eq!(svg("M1e-3 2").unwrap(), "0.001 2 m\n");
        assert_eq!(svg("M 1 2 L 3 x").unwrap(), "1 2 m\n3 NaN l\n");
        assert_eq!(svg("10 20 L 1 2").unwrap(), "10 20 l\n1 2 l\n");
        assert_eq!(svg("M 5 6 Z 1").unwrap(), "5 6 m\nh\nh\n");
    }

    #[test]
    fn svg_paths_like_pdf_lib() {
        // outputs of pdf-lib 1.17.1 svgPathToOperators
        assert_eq!(
            ops(|o| { svg_path("M 10,10 L 20 20 h5 v-5 Z", o).unwrap() }),
            "10 10 m\n20 20 l\n25 20 l\n25 15 l\nh\n"
        );
        assert_eq!(ops(|o| { svg_path("M1-2.5.5.5", o).unwrap() }), "1 -2.5 m\n0.5 0.5 l\n");
        assert_eq!(
            ops(|o| { svg_path("M0 0 Q 5 5 10 0 T 20 0", o).unwrap() }),
            "0 0 m\n5 5 10 0 v\n15 -5 20 0 v\n"
        );
        assert_eq!(
            ops(|o| { svg_path("M0 0 A 10 10 0 0 1 20 0", o).unwrap() })
                .matches(" c\n")
                .count(),
            2
        );
    }

    #[test]
    fn words_like_pdf_lib() {
        let w = |t: &str, b: &[&str]| {
            let chars: Vec<char> = t.chars().collect();
            let breaks: Vec<Vec<char>> = b.iter().map(|b| b.chars().collect()).collect();
            words(&chars, &breaks)
        };
        assert_eq!(w("ab cd\nef", &[" "]), ["ab ", "cd", "\n", "ef", ""]);
        assert_eq!(w("abc", &[""]), ["a", "b", "c", ""]);
        assert_eq!(w("a-b c", &["-", " "]), ["a-", "b ", "c", ""]);
    }

    #[test]
    fn draw_and_save() {
        let mut d = create(false, b"");
        let p = new_page(&mut d.pdf, 200.0, 200.0);
        insert_page(&mut d.pdf, 0, p).unwrap();
        let f = font::embed(&mut d.pdf, 4, None).unwrap();
        d.draw.fonts.insert(f, 4);
        let mut nums = vec![f64::NAN; ARGS];
        nums[2] = -1.0;
        nums[3..8].copy_from_slice(&[2.0, 1.0, 0.0, 0.0, 0.0]);
        nums[8] = 0.0;
        nums.extend([
            crate::document::ref_to_i64(f) as f64,
            12.0,
            0.0,
            0.0,
            0.0,
            10.0,
            20.0,
            14.0,
            f64::NAN,
            5.0,
        ]);
        draw(&mut d, p, TEXT, &nums, b"Hello").unwrap();
        // opacity: an ExtGState, reused by the second call
        nums[0] = 0.5;
        draw(&mut d, p, TEXT, &nums, b"Hello").unwrap();
        draw(&mut d, p, TEXT, &nums, b"Hello").unwrap();
        let stream = d.draw.pages[&p].content.unwrap();
        let text = String::from_utf8(d.pdf.get_object(stream).unwrap().as_stream().unwrap().content.clone()).unwrap();
        assert!(
            text.starts_with(
                "q\nBT\n1 0 0 rg\n/Helvetica-1 12 Tf\n14 TL\n1 0 0 1 10 20 Tm\n<48656C6C6F> Tj\nT*\nET\nQ\n"
            )
        );
        assert_eq!(text.matches("/GS-1 gs").count(), 2);
        let bytes = crate::document::save(&mut d, 0).unwrap();
        let again = crate::document::load(&bytes, 0, b"").unwrap();
        let s = again.pdf.get_object(stream).unwrap().as_stream().unwrap();
        assert_eq!(s.dict.get(b"Filter").unwrap().as_name().unwrap(), b"FlateDecode");
        assert_eq!(s.decompressed_content().unwrap(), text.as_bytes());
        // the stream is plain again in memory
        assert!(
            d.pdf
                .get_object(stream)
                .unwrap()
                .as_stream()
                .unwrap()
                .dict
                .get(b"Filter")
                .is_err()
        );
    }

    #[test]
    fn save_compresses_plain_page_content() {
        // eg. a page copied from a drawn page: a plain stream with the mark
        let mut d = create(false, b"");
        let p = new_page(&mut d.pdf, 100.0, 100.0);
        insert_page(&mut d.pdf, 0, p).unwrap();
        let plain = new_stream(&mut d.pdf, b"0 0 m\n".to_vec());
        let other = d
            .pdf
            .add_object(Object::Stream(Stream::new(Dictionary::new(), b"1 1 m\n".to_vec())));
        let list = vec![Object::Reference(plain), Object::Reference(other)];
        page_dict_mut(&mut d.pdf, p)
            .unwrap()
            .set("Contents", Object::Array(list));
        let bytes = crate::document::save(&mut d, 0).unwrap();
        let again = crate::document::load(&bytes, 0, b"").unwrap();
        let s = again.pdf.get_object(plain).unwrap().as_stream().unwrap();
        assert_eq!(s.dict.get(b"Filter").unwrap().as_name().unwrap(), b"FlateDecode");
        assert_eq!(s.decompressed_content().unwrap(), b"0 0 m\n");
        assert!(!s.dict.has(PLAIN_MARK));
        // a plain stream not made here (eg. from a loaded file) stays plain
        let o = again.pdf.get_object(other).unwrap().as_stream().unwrap();
        assert!(o.dict.get(b"Filter").is_err());
        // the document in memory keeps it plain
        assert!(
            d.pdf
                .get_object(plain)
                .unwrap()
                .as_stream()
                .unwrap()
                .dict
                .get(b"Filter")
                .is_err()
        );
    }

    #[test]
    fn unencodable_text_is_an_error() {
        let mut d = create(false, b"");
        let p = new_page(&mut d.pdf, 200.0, 200.0);
        let f = font::embed(&mut d.pdf, 4, None).unwrap();
        d.draw.fonts.insert(f, 4);
        let mut nums = vec![f64::NAN; ARGS];
        nums[2] = -1.0;
        nums[3] = 0.0;
        nums[8] = 0.0;
        nums.extend([
            crate::document::ref_to_i64(f) as f64,
            12.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            14.0,
            f64::NAN,
            4.0,
        ]);
        let e = draw(&mut d, p, TEXT, &nums, "a\u{4e16}".as_bytes()).unwrap_err();
        assert!(e.message.contains("WinAnsi cannot encode"));
    }
}
