//! Embedded pages: a page of this or another document as a Form XObject
//! (pdf-lib's `PDFPageEmbedder`), and `page.drawPage`.
//!
//! Speed: the main user loads one template and embeds its pages into many
//! outputs. So objects are copied from the parsed source (no new parse), a
//! single content stream keeps its compressed bytes as they are, and the
//! same source page embedded twice into one document gives the same XObject.
//!
//! A page of the same document is built at save, like pdf-lib, so drawing
//! on that page after the embed is in the XObject too.

use std::collections::{HashMap, VecDeque};
use std::ffi::c_void;
use std::sync::{Arc, Weak};

use lopdf::{Dictionary, Document, Object, ObjectId, Stream};

use crate::document::{deref, inherited, num, page_dict, ref_from_i64, ref_to_i64};
use crate::draw::{self, deflate};
use crate::ffi_util::*;
use crate::page::{MEDIA, get_box};

/// Most bytes the content of one page may decode to, for all its streams
/// together. A broken or hostile file can hold a small stream that inflates
/// to gigabytes, and list it many times.
const MAX_CONTENT: usize = if cfg!(test) { 1 << 20 } else { 256 << 20 };

/// A page plus the bounding box and matrix it was embedded with (as bits).
type Key = (ObjectId, [u64; 10]);

/// What was embedded from one source document.
#[derive(Clone)]
struct Source {
    /// Weak, so a dropped source can be seen. While it lives, the address
    /// can not be used by another document.
    doc: Weak<Shared>,
    /// Source object id to the id of its copy here.
    ids: HashMap<ObjectId, ObjectId>,
    pages: HashMap<Key, ObjectId>,
    /// `Doc::generation` of the source when the copies were made. When the
    /// source changed since, the copies are dropped and made again.
    generation: u64,
}

/// A page of this document, embedded at save: `(XObject id, page, bbox,
/// matrix)`.
type Pending = (ObjectId, ObjectId, [f64; 4], [f64; 6]);

/// Embed state of a document. Part of `Doc`.
#[derive(Clone, Default)]
pub struct EmbedState {
    sources: Vec<Source>,
    /// Pages of this document to embed at save (pdf-lib is lazy here).
    pending: Vec<Pending>,
}

/// One page to embed: `bbox` = left, bottom, right, top; `matrix` = a..f.
#[derive(Clone, Copy)]
pub struct Request {
    pub page: ObjectId,
    pub bbox: Option<[f64; 4]>,
    pub matrix: Option<[f64; 6]>,
}

/// The made XObject and its width and height.
pub type Embedded = (ObjectId, f64, f64);

/// pdf-lib's defaults: the full media box (at 0, 0, like pdf-lib), and a
/// matrix that moves the box corner to 0, 0.
fn resolve(pdf: &Document, r: &Request) -> Result<([f64; 4], [f64; 6])> {
    let bbox = match r.bbox {
        Some(b) => b,
        None => {
            let media = get_box(pdf, r.page, MEDIA)?;
            [0.0, 0.0, media[2], media[3]]
        }
    };
    let matrix = r.matrix.unwrap_or([1.0, 0.0, 0.0, 1.0, -bbox[0], -bbox[1]]);
    Ok((bbox, matrix))
}

fn key(page: ObjectId, bbox: &[f64; 4], matrix: &[f64; 6]) -> Key {
    let mut bits = [0u64; 10];
    for (b, v) in bits.iter_mut().zip(bbox.iter().chain(matrix)) {
        *b = v.to_bits();
    }
    (page, bits)
}

/// The content streams of a page (`Contents` is a stream or an array).
fn contents<'a>(pdf: &'a Document, page: &'a Dictionary) -> Result<Vec<&'a Stream>> {
    let missing = || Error::new(ERR_MISSING_CONTENTS, "Can't embed page with missing Contents");
    let value = page
        .get(b"Contents")
        .ok()
        .and_then(|v| deref(pdf, v))
        .ok_or_else(missing)?;
    let items: Vec<&Object> = match value {
        Object::Stream(_) => vec![value],
        Object::Array(a) => a.iter().filter_map(|o| deref(pdf, o)).collect(),
        _ => return Err(missing()),
    };
    items
        .into_iter()
        .map(|o| match o {
            Object::Stream(s) => Ok(s),
            other => Err(Error::generic(format!(
                "Unrecognized stream type: {}",
                other.enum_variant()
            ))),
        })
        .collect()
}

/// Makes the Form XObject of one page. `map` turns an object of the source
/// into an object of the target (a copy across documents, or a clone).
fn form(
    src: &Document,
    page: ObjectId,
    bbox: [f64; 4],
    matrix: [f64; 6],
    map: &mut dyn FnMut(&Object) -> Object,
) -> Result<Stream> {
    let dict = page_dict(src, page)?;
    let streams = contents(src, dict)?;
    let empty = Object::Dictionary(Dictionary::new());
    let resources = inherited(src, dict, b"Resources").unwrap_or(&empty);

    let mut x = Dictionary::new();
    x.set("Type", Object::Name(b"XObject".to_vec()));
    x.set("Subtype", Object::Name(b"Form".to_vec()));
    x.set("FormType", Object::Integer(1));
    x.set("BBox", Object::Array(bbox.iter().map(|v| num(*v)).collect()));
    x.set("Matrix", Object::Array(matrix.iter().map(|v| num(*v)).collect()));
    // `inherited` gives the dict itself, so the XObject gets its own copy
    // of it (direct). The objects it points at (fonts, images) are copied
    // once per target and shared.
    x.set("Resources", map(resources));

    let content = if let [one] = &streams[..] {
        // one stream: keep its bytes and filter, no decode and encode
        for k in [&b"Filter"[..], b"DecodeParms"] {
            if let Ok(v) = one.dict.get(k) {
                x.set(k, map(v));
            }
        }
        if one.dict.has(b"Filter") {
            one.content.clone()
        } else {
            // a plain stream (eg. drawn here and not saved yet): compress it
            x.set("Filter", Object::Name(b"FlateDecode".to_vec()));
            deflate(&one.content)?
        }
    } else {
        // many streams: join them like pdf-lib (each one, then a newline)
        // one budget for all streams: the same stream listed many times
        // can not grow past it
        let mut plain = Vec::new();
        for s in &streams {
            let left = MAX_CONTENT.saturating_sub(plain.len());
            plain.extend(s.get_plain_content_with_limit(left)?);
            plain.push(b'\n');
        }
        x.set("Filter", Object::Name(b"FlateDecode".to_vec()));
        deflate(&plain)?
    };
    Ok(Stream::new(x, content))
}

/// Copies objects of `src` into `dst`. Each source object is copied once
/// per target (the id map lives in the target), so pages that share fonts
/// share the copies.
struct Copier<'a> {
    src: &'a Document,
    dst: &'a mut Document,
    ids: &'a mut HashMap<ObjectId, ObjectId>,
    queue: VecDeque<ObjectId>,
}

impl Copier<'_> {
    fn copy(&mut self, obj: &Object) -> Object {
        let out = self.remap(obj);
        while let Some(id) = self.queue.pop_front() {
            let new_id = self.ids[&id];
            // a missing object stays missing, like a ref to nothing in pdf-lib
            let Some(obj) = self.src.objects.get(&id) else { continue };
            let mut copy = self.remap(obj);
            // a link to a page must not pull the whole source page tree
            if let Object::Dictionary(d) = &mut copy
                && matches!(d.get(b"Type"), Ok(Object::Name(n)) if n == b"Page")
            {
                d.remove(b"Parent");
            }
            self.dst.objects.insert(new_id, copy);
        }
        out
    }

    fn remap(&mut self, obj: &Object) -> Object {
        match obj {
            Object::Reference(id) => {
                let new_id = match self.ids.get(id) {
                    Some(n) => *n,
                    None => {
                        let n = self.dst.new_object_id();
                        self.ids.insert(*id, n);
                        self.queue.push_back(*id);
                        n
                    }
                };
                Object::Reference(new_id)
            }
            Object::Array(items) => Object::Array(items.iter().map(|o| self.remap(o)).collect()),
            Object::Dictionary(d) => Object::Dictionary(self.remap_dict(d)),
            Object::Stream(s) => {
                let mut s = s.clone();
                s.dict = self.remap_dict(&s.dict);
                Object::Stream(s)
            }
            other => other.clone(),
        }
    }

    fn remap_dict(&mut self, d: &Dictionary) -> Dictionary {
        let mut out = Dictionary::new();
        for (k, v) in d.iter() {
            out.set(k.clone(), self.remap(v));
        }
        out
    }
}

/// Embeds pages of the same document (no copy). Like pdf-lib, the XObject
/// is made at save (`flush`), so later drawing on the page is in it. Each
/// call gives a new XObject, also like pdf-lib.
pub fn embed_own(doc: &mut Doc, reqs: &[Request]) -> Result<Vec<Embedded>> {
    let mut out = Vec::with_capacity(reqs.len());
    for r in reqs {
        page_dict(&doc.pdf, r.page)?;
        let (bbox, matrix) = resolve(&doc.pdf, r)?;
        let id = doc.pdf.new_object_id();
        doc.embed.pending.push((id, r.page, bbox, matrix));
        out.push((id, bbox[2] - bbox[0], bbox[3] - bbox[1]));
    }
    Ok(out)
}

/// Makes the XObjects of `embed_own`. Save runs it. They are made once,
/// like pdf-lib's `alreadyEmbedded`. On an error, all stay pending.
/// Returns true when it made some.
pub fn flush(doc: &mut Doc) -> Result<bool> {
    if doc.embed.pending.is_empty() {
        return Ok(false);
    }
    let mut made = Vec::with_capacity(doc.embed.pending.len());
    for &(id, page, bbox, matrix) in &doc.embed.pending {
        made.push((id, form(&doc.pdf, page, bbox, matrix, &mut |o| o.clone())?));
    }
    for (id, stream) in made {
        doc.pdf.objects.insert(id, Object::Stream(stream));
    }
    doc.embed.pending.clear();
    Ok(true)
}

/// Before objects are copied out of `doc` (embed or copyPages into another
/// document): make its pending XObjects, so a copy does not point at an
/// object that is not there yet.
pub fn flush_source(doc: &mut Doc) -> Result<()> {
    if flush(doc)? {
        doc.generation = doc.generation.wrapping_add(1);
    }
    Ok(())
}

/// Embeds pages of another document `src` (pdf-lib copies the page with
/// `PDFObjectCopier` first).
pub fn embed_foreign(doc: &mut Doc, src: &Doc, src_arc: &Arc<Shared>, reqs: &[Request]) -> Result<Vec<Embedded>> {
    let state = &mut doc.embed;
    state.sources.retain(|s| s.doc.strong_count() > 0);
    let at = match state
        .sources
        .iter()
        .position(|s| s.doc.as_ptr() == Arc::as_ptr(src_arc))
    {
        Some(i) => i,
        None => {
            state.sources.push(Source {
                doc: Arc::downgrade(src_arc),
                ids: HashMap::new(),
                pages: HashMap::new(),
                generation: src.generation,
            });
            state.sources.len() - 1
        }
    };
    let source = &mut state.sources[at];
    if source.generation != src.generation {
        // the source changed: its old copies may be out of date
        source.ids.clear();
        source.pages.clear();
        source.generation = src.generation;
    }
    let mut out = Vec::with_capacity(reqs.len());
    for r in reqs {
        let (bbox, matrix) = resolve(&src.pdf, r)?;
        let k = key(r.page, &bbox, &matrix);
        let id = match source.pages.get(&k) {
            Some(id) => *id,
            None => {
                let mut copier = Copier {
                    src: &src.pdf,
                    dst: &mut doc.pdf,
                    ids: &mut source.ids,
                    queue: VecDeque::new(),
                };
                let stream = form(&src.pdf, r.page, bbox, matrix, &mut |o| copier.copy(o))?;
                let id = doc.pdf.add_object(stream);
                source.pages.insert(k, id);
                id
            }
        };
        out.push((id, bbox[2] - bbox[0], bbox[3] - bbox[1]));
    }
    Ok(out)
}

// ---------------------------------------------------------------- drawPage

/// drawPage values, as pdf-lib computes them before `drawPage(...)` ops.
#[derive(Clone, Copy)]
pub struct Draw {
    pub x: f64,
    pub y: f64,
    pub x_scale: f64,
    pub y_scale: f64,
    /// radians
    pub rotate: f64,
    pub x_skew: f64,
    pub y_skew: f64,
    /// NaN = none
    pub opacity: f64,
    /// -1 = none
    pub blend: i32,
}

/// pdf-lib's `page.drawPage`: `q [gs] cm(translate) cm(rotate) cm(scale)
/// cm(skew) /Name Do Q`.
pub fn draw_page(doc: &mut Doc, page: ObjectId, xobject: ObjectId, d: Draw) -> Result<()> {
    let pending = doc.embed.pending.iter().any(|p| p.0 == xobject);
    if !pending && !matches!(doc.pdf.objects.get(&xobject), Some(Object::Stream(_))) {
        return Err(Error::generic("the embedded page is not in this document"));
    }
    page_dict(&doc.pdf, page)?;
    // the drawing layer's names, resources and content stream: one stream
    // per page, so drawPage and drawText keep their call order
    let name = draw::xobject_name(doc, page, xobject, "EmbeddedPdfPage")?;
    let gs = draw::graphics_state_name(doc, page, d.opacity, f64::NAN, d.blend)?;

    let mut ops = Vec::with_capacity(160);
    let cm = |ops: &mut Vec<u8>, m: [f64; 6]| {
        for v in m {
            draw::write_num(ops, v);
            ops.push(b' ');
        }
        ops.extend_from_slice(b"cm\n");
    };
    ops.extend_from_slice(b"q\n");
    if let Some(n) = &gs {
        ops.push(b'/');
        ops.extend_from_slice(n);
        ops.extend_from_slice(b" gs\n");
    }
    let (sin, cos) = d.rotate.sin_cos();
    cm(&mut ops, [1.0, 0.0, 0.0, 1.0, d.x, d.y]);
    cm(&mut ops, [cos, sin, -sin, cos, 0.0, 0.0]);
    cm(&mut ops, [d.x_scale, 0.0, 0.0, d.y_scale, 0.0, 0.0]);
    cm(&mut ops, [1.0, d.x_skew.tan(), d.y_skew.tan(), 1.0, 0.0, 0.0]);
    ops.push(b'/');
    ops.extend_from_slice(&name);
    ops.extend_from_slice(b" Do\nQ\n");
    draw::append_content(doc, page, &ops)
}

// ---------------------------------------------------------------- exports

fn f64s<'a>(ptr: *const f64, len: usize) -> Result<&'a [f64]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(Error::generic("bad input buffer"));
    }
    // SAFETY: Dart passes `len` doubles that live for the call.
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// All NaN = none; all finite = the values; anything else is an error.
fn optional<const N: usize>(v: &[f64], what: &str) -> Result<Option<[f64; N]>> {
    if v.iter().all(|x| x.is_nan()) {
        return Ok(None);
    }
    if !v.iter().all(|x| x.is_finite()) {
        return Err(Error::generic(format!("`{what}` values must be finite numbers")));
    }
    let mut out = [0.0; N];
    out.copy_from_slice(v);
    Ok(Some(out))
}

/// Embeds `n` pages (`pages` = page refs of `src`) into `dst`.
/// `boxes` = n * 4 (left, bottom, right, top), `matrices` = n * 6; all NaN
/// means "default". `out_refs` gets n XObject refs, `out_sizes`
/// n * 2 (width, height).
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_embed_pages(
    dst: *const c_void,
    src: *const c_void,
    pages: *const i64,
    n: i64,
    boxes: *const f64,
    matrices: *const f64,
    out_refs: *mut i64,
    out_sizes: *mut f64,
) -> i32 {
    call(|| {
        let n = usize::try_from(n).map_err(|_| Error::generic("bad input buffer"))?;
        if n > 0 && (pages.is_null() || out_refs.is_null() || out_sizes.is_null()) {
            return Err(Error::generic("bad input buffer"));
        }
        // SAFETY: Dart passes n page refs.
        let pages = if n == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(pages, n) }
        };
        let boxes = f64s(boxes, n * 4)?;
        let matrices = f64s(matrices, n * 6)?;
        let mut reqs = Vec::with_capacity(n);
        for (i, page) in pages.iter().enumerate() {
            reqs.push(Request {
                page: ref_from_i64(*page),
                bbox: optional::<4>(&boxes[i * 4..i * 4 + 4], "boundingBox")?,
                matrix: optional::<6>(&matrices[i * 6..i * 6 + 6], "transformationMatrix")?,
            });
        }
        let dst_arc = handle_arc(dst)?;
        let src_arc = handle_arc(src)?;
        let done = if Arc::ptr_eq(&dst_arc, &src_arc) {
            let mut d = lock(&dst_arc)?;
            d.generation = d.generation.wrapping_add(1);
            embed_own(&mut d, &reqs)?
        } else {
            // both locks at once, always in address order: no deadlock when
            // two threads embed a -> b and b -> a
            let dst_first = Arc::as_ptr(&dst_arc) < Arc::as_ptr(&src_arc);
            let (mut d, mut s) = if dst_first {
                let d = lock(&dst_arc)?;
                (d, lock(&src_arc)?)
            } else {
                let s = lock(&src_arc)?;
                (lock(&dst_arc)?, s)
            };
            flush_source(&mut s)?;
            d.generation = d.generation.wrapping_add(1);
            embed_foreign(&mut d, &s, &src_arc, &reqs)?
        };
        for (i, (id, w, h)) in done.into_iter().enumerate() {
            // SAFETY: Dart passes room for n refs and n * 2 sizes.
            unsafe {
                *out_refs.add(i) = ref_to_i64(id);
                *out_sizes.add(i * 2) = w;
                *out_sizes.add(i * 2 + 1) = h;
            }
        }
        Ok(OK)
    })
}

/// `values` = x, y, xScale, yScale, rotate, xSkew, ySkew (radians),
/// opacity (NaN = none). `blend` = index of the blend mode or -1.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_draw_page(
    handle: *const c_void,
    page: i64,
    xobject: i64,
    values: *const f64,
    blend: i32,
) -> i32 {
    call(|| {
        let v = f64s(values, 8)?;
        let d = Draw {
            x: v[0],
            y: v[1],
            x_scale: v[2],
            y_scale: v[3],
            rotate: v[4],
            x_skew: v[5],
            y_skew: v[6],
            opacity: v[7],
            blend,
        };
        with_doc_mut(handle, |doc| {
            draw_page(doc, ref_from_i64(page), ref_from_i64(xobject), d).map(|_| OK)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::{create, insert_page, new_page, page_dict_mut};

    /// A page with two content streams and resources on the parent node.
    fn source() -> (Doc, ObjectId) {
        let mut d = create(false, b"");
        let p = new_page(&mut d.pdf, 200.0, 100.0);
        insert_page(&mut d.pdf, 0, p).unwrap();
        let mut font = Dictionary::new();
        font.set("Type", Object::Name(b"Font".to_vec()));
        font.set("BaseFont", Object::Name(b"Helvetica".to_vec()));
        let font = d.pdf.add_object(font);
        let mut fonts = Dictionary::new();
        fonts.set("F1", Object::Reference(font));
        let mut res = Dictionary::new();
        res.set("Font", Object::Dictionary(fonts));
        let parent = match page_dict(&d.pdf, p).unwrap().get(b"Parent").unwrap() {
            Object::Reference(r) => *r,
            _ => unreachable!(),
        };
        page_dict_mut(&mut d.pdf, p).unwrap().remove(b"Resources");
        page_dict_mut(&mut d.pdf, parent)
            .unwrap()
            .set("Resources", Object::Dictionary(res));
        let mut flate = Dictionary::new();
        flate.set("Filter", Object::Name(b"FlateDecode".to_vec()));
        let a = Stream::new(flate, deflate(b"BT /F1 12 Tf (hi) Tj ET").unwrap());
        let a = d.pdf.add_object(a);
        let b = d
            .pdf
            .add_object(Stream::new(Dictionary::new(), b"0 0 10 10 re f".to_vec()));
        page_dict_mut(&mut d.pdf, p).unwrap().set(
            "Contents",
            Object::Array(vec![Object::Reference(a), Object::Reference(b)]),
        );
        (d, p)
    }

    fn req(page: ObjectId) -> Request {
        Request {
            page,
            bbox: None,
            matrix: None,
        }
    }

    #[test]
    fn embeds_a_foreign_page_once_with_inherited_resources() {
        let (src, p) = source();
        let src = Arc::new(std::sync::Mutex::new(src));
        let mut dst = create(false, b"");
        let s = src.lock().unwrap();
        let first = embed_foreign(&mut dst, &s, &src, &[req(p), req(p)]).unwrap();
        assert_eq!(first[0], first[1]);
        assert_eq!((first[0].1, first[0].2), (200.0, 100.0));
        let count = dst.pdf.objects.len();
        let again = embed_foreign(&mut dst, &s, &src, &[req(p)]).unwrap();
        assert_eq!(again[0].0, first[0].0);
        assert_eq!(dst.pdf.objects.len(), count);

        let x = dst.pdf.get_object(first[0].0).unwrap().as_stream().unwrap();
        let font = x
            .dict
            .get(b"Resources")
            .unwrap()
            .as_dict()
            .unwrap()
            .get(b"Font")
            .unwrap();
        let f1 = font.as_dict().unwrap().get(b"F1").unwrap().as_reference().unwrap();
        assert!(dst.pdf.get_object(f1).unwrap().as_dict().unwrap().has(b"BaseFont"));
        let plain = x.get_plain_content().unwrap();
        assert_eq!(plain, b"BT /F1 12 Tf (hi) Tj ET\n0 0 10 10 re f\n");

        // another box is another XObject, and the font is not copied again
        let boxed = Request {
            page: p,
            bbox: Some([10.0, 10.0, 50.0, 40.0]),
            matrix: None,
        };
        let other = embed_foreign(&mut dst, &s, &src, &[boxed]).unwrap();
        assert_ne!(other[0].0, first[0].0);
        assert_eq!((other[0].1, other[0].2), (40.0, 30.0));
        assert_eq!(dst.pdf.objects.len(), count + 1);
        let x = dst.pdf.get_object(other[0].0).unwrap().as_stream().unwrap();
        let m: Vec<f64> = x
            .dict
            .get(b"Matrix")
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .map(|o| crate::document::as_f64(o).unwrap())
            .collect();
        assert_eq!(m, [1.0, 0.0, 0.0, 1.0, -10.0, -10.0]);
    }

    #[test]
    fn one_stream_keeps_its_bytes() {
        let (mut d, p) = source();
        let a = page_dict(&d.pdf, p)
            .unwrap()
            .get(b"Contents")
            .unwrap()
            .as_array()
            .unwrap()[0]
            .clone();
        page_dict_mut(&mut d.pdf, p).unwrap().set("Contents", a.clone());
        let raw = d
            .pdf
            .get_object(a.as_reference().unwrap())
            .unwrap()
            .as_stream()
            .unwrap()
            .content
            .clone();
        let out = embed_own(&mut d, &[req(p)]).unwrap();
        assert!(d.pdf.get_object(out[0].0).is_err(), "made at save, not now");
        flush(&mut d).unwrap();
        let x = d.pdf.get_object(out[0].0).unwrap().as_stream().unwrap();
        assert_eq!(x.content, raw);
        assert_eq!(x.dict.get(b"Filter").unwrap().as_name().unwrap(), b"FlateDecode");
    }

    #[test]
    fn missing_contents_is_an_error() {
        let mut d = create(false, b"");
        let p = new_page(&mut d.pdf, 10.0, 10.0);
        insert_page(&mut d.pdf, 0, p).unwrap();
        embed_own(&mut d, &[req(p)]).unwrap();
        // like pdf-lib, the error comes at save
        assert_eq!(flush(&mut d).unwrap_err().status, ERR_MISSING_CONTENTS);
    }

    #[test]
    fn own_page_has_the_drawing_made_after_the_embed() {
        let (mut d, p) = source();
        let a = embed_own(&mut d, &[req(p)]).unwrap()[0].0;
        let b = embed_own(&mut d, &[req(p)]).unwrap()[0].0;
        assert_ne!(a, b, "own pages are not cached, like pdf-lib");
        draw::append_content(&mut d, p, b"1 0 0 RG\n").unwrap();
        flush(&mut d).unwrap();
        let x = d.pdf.get_object(a).unwrap().as_stream().unwrap();
        let text = String::from_utf8(x.get_plain_content().unwrap()).unwrap();
        assert!(text.contains("1 0 0 RG"), "{text}");
    }

    #[test]
    fn one_budget_for_all_streams_of_a_page() {
        let (mut d, p) = source();
        let mut flate = Dictionary::new();
        flate.set("Filter", Object::Name(b"FlateDecode".to_vec()));
        let bomb = d
            .pdf
            .add_object(Stream::new(flate, deflate(&[b' '; 64 << 10]).unwrap()));
        let list = vec![Object::Reference(bomb); 20];
        page_dict_mut(&mut d.pdf, p)
            .unwrap()
            .set("Contents", Object::Array(list));
        embed_own(&mut d, &[req(p)]).unwrap();
        assert!(flush(&mut d).is_err());
    }

    #[test]
    fn a_changed_source_is_copied_again() {
        let (mut src, p) = source();
        src.generation = 1;
        let shared = Arc::new(std::sync::Mutex::new(src));
        let mut dst = create(false, b"");
        let first = {
            let s = shared.lock().unwrap();
            embed_foreign(&mut dst, &s, &shared, &[req(p)]).unwrap()[0].0
        };
        shared.lock().unwrap().generation = 2;
        let s = shared.lock().unwrap();
        let second = embed_foreign(&mut dst, &s, &shared, &[req(p)]).unwrap()[0].0;
        assert_ne!(first, second);
        let third = embed_foreign(&mut dst, &s, &shared, &[req(p)]).unwrap()[0].0;
        assert_eq!(second, third);
    }

    #[test]
    fn draw_page_writes_ops_and_resources() {
        let (mut d, p) = source();
        let x = embed_own(&mut d, &[req(p)]).unwrap()[0].0;
        flush(&mut d).unwrap();
        let target = new_page(&mut d.pdf, 300.0, 300.0);
        insert_page(&mut d.pdf, 1, target).unwrap();
        let draw = Draw {
            x: 10.0,
            y: 20.0,
            x_scale: 0.5,
            y_scale: 0.5,
            rotate: 0.0,
            x_skew: 0.0,
            y_skew: 0.0,
            opacity: 0.5,
            blend: 1,
        };
        draw_page(&mut d, target, x, draw).unwrap();
        draw_page(
            &mut d,
            target,
            x,
            Draw {
                opacity: f64::NAN,
                blend: -1,
                ..draw
            },
        )
        .unwrap();
        let page = page_dict(&d.pdf, target).unwrap();
        let res = page.get(b"Resources").unwrap().as_dict().unwrap();
        let xo = res.get(b"XObject").unwrap().as_dict().unwrap();
        assert_eq!(xo.len(), 1, "the same XObject keeps its name");
        let gs = res.get(b"ExtGState").unwrap().as_dict().unwrap();
        let g = gs.get(b"GS-1").unwrap().as_dict().unwrap();
        assert_eq!(g.get(b"BM").unwrap().as_name().unwrap(), b"Multiply");
        let contents = page.get(b"Contents").unwrap().as_array().unwrap();
        assert_eq!(contents.len(), 1, "a new page has no old content to wrap");
        let s = d
            .pdf
            .get_object(contents[0].as_reference().unwrap())
            .unwrap()
            .as_stream()
            .unwrap();
        let text = String::from_utf8(s.content.clone()).unwrap();
        assert_eq!(text.matches("/EmbeddedPdfPage-1 Do").count(), 2);
        assert!(text.starts_with("q\n/GS-1 gs\n1 0 0 1 10 20 cm\n"));

        // a page with content gets it wrapped in q ... Q
        draw_page(&mut d, p, x, draw).unwrap();
        let contents = page_dict(&d.pdf, p)
            .unwrap()
            .get(b"Contents")
            .unwrap()
            .as_array()
            .unwrap();
        assert_eq!(contents.len(), 5);
    }

    #[test]
    fn a_pending_embed_of_the_source_is_made_before_the_copy() {
        let (mut src, p) = source();
        let x = embed_own(&mut src, &[req(p)]).unwrap()[0].0;
        let t = new_page(&mut src.pdf, 100.0, 100.0);
        insert_page(&mut src.pdf, 1, t).unwrap();
        // the template page draws its own first page, still pending
        let draw = Draw {
            x: 0.0,
            y: 0.0,
            x_scale: 1.0,
            y_scale: 1.0,
            rotate: 0.0,
            x_skew: 0.0,
            y_skew: 0.0,
            opacity: f64::NAN,
            blend: -1,
        };
        draw_page(&mut src, t, x, draw).unwrap();
        flush_source(&mut src).unwrap();
        let shared = Arc::new(std::sync::Mutex::new(src));
        let mut dst = create(false, b"");
        let s = shared.lock().unwrap();
        let e = embed_foreign(&mut dst, &s, &shared, &[req(t)]).unwrap()[0].0;
        let form = dst.pdf.get_object(e).unwrap().as_stream().unwrap();
        let res = form.dict.get(b"Resources").unwrap().as_dict().unwrap();
        let xo = res.get(b"XObject").unwrap().as_dict().unwrap();
        let inner = xo.iter().next().unwrap().1.as_reference().unwrap();
        assert!(dst.pdf.get_object(inner).unwrap().as_stream().is_ok());
    }
}
