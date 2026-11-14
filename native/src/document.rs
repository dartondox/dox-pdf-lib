//! The document: create, load, save, and the page tree (list, insert,
//! remove, copy pages from another document).

use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::c_void;

use lopdf::{Dictionary, Document, Object, ObjectId, SaveOptions};

use crate::ffi_util::*;
use crate::metadata;

/// pdf-lib's `PageSizes.A4`, the size of a new page.
pub const A4: (f64, f64) = (595.28, 841.89);

/// Most links followed when we walk up `/Parent` or down `/Kids`. A broken
/// file can have a loop, so every walk has a limit.
const MAX_DEPTH: usize = 256;

/// `ObjectId` to the i64 that Dart holds: number << 16 | generation.
pub fn ref_to_i64(id: ObjectId) -> i64 {
    ((id.0 as i64) << 16) | id.1 as i64
}

pub fn ref_from_i64(v: i64) -> ObjectId {
    ((v >> 16) as u32, (v & 0xffff) as u16)
}

/// Follows references (with a limit) to the real object.
pub fn deref<'a>(doc: &'a Document, mut obj: &'a Object) -> Option<&'a Object> {
    for _ in 0..MAX_DEPTH {
        match obj {
            Object::Reference(id) => obj = doc.objects.get(id)?,
            _ => return Some(obj),
        }
    }
    None
}

pub fn dict_get<'a>(doc: &'a Document, dict: &'a Dictionary, key: &[u8]) -> Option<&'a Object> {
    deref(doc, dict.get(key).ok()?)
}

/// A number as f64. lopdf keeps reals as f32, so we go through the shortest
/// decimal text: 841.89 stays 841.89, not 841.8900146484375.
pub fn as_f64(obj: &Object) -> Option<f64> {
    match obj {
        Object::Integer(i) => Some(*i as f64),
        Object::Real(r) => r.to_string().parse().ok(),
        _ => None,
    }
}

/// A number object: an integer when the value is whole, like pdf-lib writes.
pub fn num(v: f64) -> Object {
    if v.fract() == 0.0 && v.abs() < 1e15 {
        Object::Integer(v as i64)
    } else {
        Object::Real(v as f32)
    }
}

pub fn page_dict(doc: &Document, id: ObjectId) -> Result<&Dictionary> {
    match doc.objects.get(&id) {
        Some(Object::Dictionary(d)) => Ok(d),
        _ => Err(Error::generic(format!("object {} {} R is not a page", id.0, id.1))),
    }
}

pub fn page_dict_mut(doc: &mut Document, id: ObjectId) -> Result<&mut Dictionary> {
    match doc.objects.get_mut(&id) {
        Some(Object::Dictionary(d)) => Ok(d),
        _ => Err(Error::generic(format!("object {} {} R is not a page", id.0, id.1))),
    }
}

/// A value of the page, or of its nearest parent node that has it
/// (`Resources`, `MediaBox`, `CropBox` and `Rotate` are inherited).
pub fn inherited<'a>(doc: &'a Document, page: &'a Dictionary, key: &[u8]) -> Option<&'a Object> {
    let mut node = page;
    for _ in 0..MAX_DEPTH {
        if let Ok(value) = node.get(key) {
            return deref(doc, value);
        }
        match dict_get(doc, node, b"Parent") {
            Some(Object::Dictionary(parent)) => node = parent,
            _ => return None,
        }
    }
    None
}

fn root_pages(doc: &Document) -> Result<ObjectId> {
    let root = doc
        .trailer
        .get(b"Root")
        .ok()
        .and_then(|r| deref(doc, r))
        .and_then(|r| match r {
            Object::Dictionary(d) => Some(d),
            _ => None,
        })
        .ok_or_else(|| Error::generic("the document has no catalog"))?;
    match root.get(b"Pages") {
        Ok(Object::Reference(id)) if matches!(doc.objects.get(id), Some(Object::Dictionary(_))) => Ok(*id),
        _ => Err(Error::generic("the catalog has no page tree")),
    }
}

/// A tree node to walk: `(node, next kid index, path to the node)`.
type Walk = (ObjectId, usize, Vec<(ObjectId, usize)>);

/// Copied objects with ids 1.., and the new ids of the pages.
type Copied = (Vec<(u32, Object)>, Vec<u32>);

/// One leaf of the page tree and the way to it: `(node, index in Kids)`
/// for each tree node from the root down.
pub struct PageEntry {
    pub id: ObjectId,
    pub path: Vec<(ObjectId, usize)>,
}

fn kids(doc: &Document, node: ObjectId) -> Option<&Vec<Object>> {
    match doc.objects.get(&node) {
        Some(Object::Dictionary(d)) => match dict_get(doc, d, b"Kids") {
            Some(Object::Array(a)) => Some(a),
            _ => None,
        },
        _ => None,
    }
}

fn is_tree_node(doc: &Document, id: ObjectId) -> bool {
    match doc.objects.get(&id) {
        Some(Object::Dictionary(d)) => !matches!(d.get(b"Type"), Ok(Object::Name(n)) if n == b"Page") && d.has(b"Kids"),
        _ => false,
    }
}

/// All pages in order. The walk does not trust `/Count` and skips loops.
pub fn page_entries(doc: &Document) -> Result<Vec<PageEntry>> {
    let root = root_pages(doc)?;
    let mut out = Vec::new();
    let mut seen = HashSet::from([root]);
    // explicit stack, so a deep tree can not overflow the Rust stack
    let mut stack: Vec<Walk> = vec![(root, 0, Vec::new())];
    while let Some((node, idx, path)) = stack.pop() {
        let Some(list) = kids(doc, node) else { continue };
        let Some(kid) = list.get(idx) else { continue };
        stack.push((node, idx + 1, path.clone()));
        let Object::Reference(kid) = kid else { continue };
        if !seen.insert(*kid) || path.len() >= MAX_DEPTH {
            continue;
        }
        let mut here = path;
        here.push((node, idx));
        if is_tree_node(doc, *kid) {
            stack.push((*kid, 0, here));
        } else if matches!(doc.objects.get(kid), Some(Object::Dictionary(_))) {
            out.push(PageEntry { id: *kid, path: here });
        }
    }
    Ok(out)
}

fn add_count(doc: &mut Document, node: ObjectId, delta: i64) {
    if let Some(Object::Dictionary(d)) = doc.objects.get_mut(&node) {
        let count = match d.get(b"Count") {
            Ok(Object::Integer(c)) => *c,
            _ => 0,
        };
        d.set("Count", Object::Integer((count + delta).max(0)));
    }
}

fn kids_mut(doc: &mut Document, node: ObjectId) -> Result<&mut Vec<Object>> {
    // `Kids` may be a reference to an array
    let target = match doc.objects.get(&node) {
        Some(Object::Dictionary(d)) => match d.get(b"Kids") {
            Ok(Object::Reference(id)) => Some(*id),
            _ => None,
        },
        _ => None,
    };
    let array = match target {
        Some(id) => doc.objects.get_mut(&id),
        None => match doc.objects.get_mut(&node) {
            Some(Object::Dictionary(d)) => d.get_mut(b"Kids").ok(),
            _ => None,
        },
    };
    match array {
        Some(Object::Array(a)) => Ok(a),
        _ => Err(Error::generic("broken page tree: a node has no Kids")),
    }
}

/// Puts the page `page` at `index` in the page tree (pdf-lib's
/// `insertLeafNode`) and sets its `/Parent`.
pub fn insert_page(doc: &mut Document, index: usize, page: ObjectId) -> Result<()> {
    let entries = page_entries(doc)?;
    if index > entries.len() {
        return Err(range_error(index, entries.len()));
    }
    let (path, parent, at) = if index < entries.len() {
        let path = entries[index].path.clone();
        let (parent, at) = *path.last().expect("a page has a parent");
        (path, parent, at)
    } else if let Some(last) = entries.last() {
        let (parent, at) = *last.path.last().expect("a page has a parent");
        (last.path.clone(), parent, at + 1)
    } else {
        let root = root_pages(doc)?;
        let len = kids_mut(doc, root)?.len();
        (vec![(root, len)], root, len)
    };
    page_dict(doc, page)?;
    kids_mut(doc, parent)?.insert(at, Object::Reference(page));
    for (node, _) in &path {
        add_count(doc, *node, 1);
    }
    page_dict_mut(doc, page)?.set("Parent", Object::Reference(parent));
    Ok(())
}

fn range_error(index: usize, max: usize) -> Error {
    Error::new(
        ERR_RANGE,
        format!("`index` must be at least 0 and at most {max}, but was actually {index}"),
    )
}

/// Takes the page at `index` out of the page tree (pdf-lib's
/// `removeLeafNode`). Tree nodes that become empty are removed too.
pub fn remove_page(doc: &mut Document, index: usize) -> Result<()> {
    let entries = page_entries(doc)?;
    if entries.is_empty() {
        return Err(Error::new(
            ERR_EMPTY_REMOVE,
            "PDFDocument has no pages so `PDFDocument.removePage` cannot be called",
        ));
    }
    if index >= entries.len() {
        return Err(range_error(index, entries.len() - 1));
    }
    let path = &entries[index].path;
    let (parent, at) = *path.last().expect("a page has a parent");
    kids_mut(doc, parent)?.remove(at);
    for (node, _) in path {
        add_count(doc, *node, -1);
    }
    for level in (1..path.len()).rev() {
        if !kids_mut(doc, path[level].0)?.is_empty() {
            break;
        }
        let (up, at) = path[level - 1];
        kids_mut(doc, up)?.remove(at);
    }
    Ok(())
}

/// A new page dict like pdf-lib's `PDFPage.create` + `setSize(w, h)`.
pub fn new_page(doc: &mut Document, width: f64, height: f64) -> ObjectId {
    let mut page = Dictionary::new();
    page.set("Type", Object::Name(b"Page".to_vec()));
    page.set("Resources", Object::Dictionary(Dictionary::new()));
    page.set(
        "MediaBox",
        Object::Array(vec![num(0.0), num(0.0), num(width), num(height)]),
    );
    doc.add_object(Object::Dictionary(page))
}

/// pdf-lib's `PDFObjectCopier`: a deep copy of pages from `src`. Inherited
/// values move into the page and `/Parent` is dropped, so the copy does not
/// pull the whole source page tree with it. Each object is copied once.
///
/// Returns the new objects with ids 1.. (to shift onto the target) and the
/// new ids of the pages.
fn copy_pages(src: &Document, pages: &[ObjectId]) -> Result<Copied> {
    let mut map: HashMap<ObjectId, u32> = HashMap::new();
    let mut next = 0u32;
    let mut queue: VecDeque<ObjectId> = VecDeque::new();
    let mut out = Vec::new();
    let mut new_ids = Vec::with_capacity(pages.len());

    // each page gets its own new id first (a page asked for twice is copied
    // twice, like pdf-lib). A link back to a source page (eg. an
    // annotation's /P) then points at its first copy, not at a new copy.
    for id in pages {
        next += 1;
        new_ids.push(next);
        map.entry(*id).or_insert(next);
    }
    for (id, new_id) in pages.iter().zip(&new_ids) {
        let page = page_dict(src, *id)?;
        let mut clone = page.clone();
        for key in [&b"Resources"[..], b"MediaBox", b"CropBox", b"Rotate"] {
            if !clone.has(key)
                && let Some(value) = inherited(src, page, key)
            {
                clone.set(key, value.clone());
            }
        }
        clone.remove(b"Parent");
        let obj = remap(&Object::Dictionary(clone), &mut map, &mut next, &mut queue);
        out.push((*new_id, obj));
    }
    while let Some(id) = queue.pop_front() {
        let new_id = map[&id];
        // a missing object stays missing, like a ref to nothing in pdf-lib
        if let Some(obj) = src.objects.get(&id) {
            let obj = remap(obj, &mut map, &mut next, &mut queue);
            out.push((new_id, obj));
        }
    }
    Ok((out, new_ids))
}

fn remap(obj: &Object, map: &mut HashMap<ObjectId, u32>, next: &mut u32, queue: &mut VecDeque<ObjectId>) -> Object {
    match obj {
        Object::Reference(id) => {
            let new_id = *map.entry(*id).or_insert_with(|| {
                *next += 1;
                queue.push_back(*id);
                *next
            });
            Object::Reference((new_id, 0))
        }
        Object::Array(items) => Object::Array(items.iter().map(|o| remap(o, map, next, queue)).collect()),
        Object::Dictionary(d) => Object::Dictionary(remap_dict(d, map, next, queue)),
        Object::Stream(s) => {
            let mut s = s.clone();
            s.dict = remap_dict(&s.dict, map, next, queue);
            Object::Stream(s)
        }
        other => other.clone(),
    }
}

fn remap_dict(
    d: &Dictionary,
    map: &mut HashMap<ObjectId, u32>,
    next: &mut u32,
    queue: &mut VecDeque<ObjectId>,
) -> Dictionary {
    let mut out = Dictionary::new();
    for (k, v) in d.iter() {
        out.set(k.clone(), remap(v, map, next, queue));
    }
    out
}

/// Moves every reference (all point at copied objects, ids 1..) by `base`.
fn shift(obj: &mut Object, base: u32) {
    match obj {
        Object::Reference(id) => id.0 += base,
        Object::Array(items) => items.iter_mut().for_each(|o| shift(o, base)),
        Object::Dictionary(d) => d.iter_mut().for_each(|(_, v)| shift(v, base)),
        Object::Stream(s) => s.dict.iter_mut().for_each(|(_, v)| shift(v, base)),
        _ => {}
    }
}

/// pdf-lib's `PDFDocument.create()`: an empty catalog and page tree.
pub fn create(update_metadata: bool, now: &[u8]) -> Doc {
    let mut pdf = Document::with_version("1.7");
    let mut pages = Dictionary::new();
    pages.set("Type", Object::Name(b"Pages".to_vec()));
    pages.set("Kids", Object::Array(vec![]));
    pages.set("Count", Object::Integer(0));
    let pages = pdf.add_object(Object::Dictionary(pages));
    let mut catalog = Dictionary::new();
    catalog.set("Type", Object::Name(b"Catalog".to_vec()));
    catalog.set("Pages", Object::Reference(pages));
    let catalog = pdf.add_object(Object::Dictionary(catalog));
    pdf.trailer.set("Root", Object::Reference(catalog));
    if update_metadata {
        metadata::update_info(&mut pdf, now);
    }
    Doc { pdf }
}

/// Load flags from Dart.
pub const LOAD_IGNORE_ENCRYPTION: i32 = 1;
pub const LOAD_UPDATE_METADATA: i32 = 2;

pub fn load(bytes: &[u8], flags: i32, now: &[u8]) -> Result<Doc> {
    let mut pdf =
        Document::load_mem(bytes).map_err(|e| Error::new(ERR_PARSE, format!("Failed to parse PDF document: {e}")))?;
    if is_encrypted(&pdf) && flags & LOAD_IGNORE_ENCRYPTION == 0 {
        return Err(Error::new(
            ERR_ENCRYPTED,
            "Input document to `PDFDocument.load` is encrypted. You can use `PDFDocument.load(..., { ignoreEncryption: true })` if you wish to load the document anyways.",
        ));
    }
    // a file without a page tree can not be used, like in pdf-lib
    root_pages(&pdf).map_err(|e| {
        // ponytail: lopdf reads no objects of a file it can not decrypt (a
        // user password). pdf-lib can still list its pages; we can not.
        let message = if is_encrypted(&pdf) {
            "the document is encrypted with a password, so its pages can not be read".to_string()
        } else {
            e.message
        };
        Error::new(ERR_PARSE, message)
    })?;
    if flags & LOAD_UPDATE_METADATA != 0 {
        metadata::update_info(&mut pdf, now);
    }
    Ok(Doc { pdf })
}

/// Like pdf-lib: the trailer has an `/Encrypt` entry. When lopdf could
/// open the file with the empty user password, it decrypts it and drops
/// `/Encrypt`, but keeps `encryption_state`.
pub fn is_encrypted(pdf: &Document) -> bool {
    pdf.encryption_state.is_some() || pdf.trailer.get(b"Encrypt").is_ok_and(|e| !matches!(e, Object::Null))
}

pub const SAVE_OBJECT_STREAMS: i32 = 1;
pub const SAVE_ADD_DEFAULT_PAGE: i32 = 2;

pub fn save(doc: &mut Doc, flags: i32) -> Result<Vec<u8>> {
    if flags & SAVE_ADD_DEFAULT_PAGE != 0 && page_entries(&doc.pdf)?.is_empty() {
        let page = new_page(&mut doc.pdf, A4.0, A4.1);
        insert_page(&mut doc.pdf, 0, page)?;
    }
    let mut out = Vec::with_capacity(estimate_size(&doc.pdf));
    let streams = flags & SAVE_OBJECT_STREAMS != 0;
    let options = SaveOptions::builder()
        .use_object_streams(streams)
        .use_xref_streams(streams)
        .build();
    doc.pdf.save_with_options(&mut out, options)?;
    Ok(out)
}

/// About the size of the saved file. Only used to pick inline or thread.
fn estimate_size(pdf: &Document) -> usize {
    pdf.objects
        .values()
        .map(|o| match o {
            Object::Stream(s) => s.content.len() + 64,
            _ => 64,
        })
        .sum()
}

// ---------------------------------------------------------------- exports

/// `out[0]` = the new handle.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_create(flags: i32, now: *const u8, now_len: i64, out: *mut i64) -> i32 {
    call(|| {
        let doc = create(flags & LOAD_UPDATE_METADATA != 0, slice(now, now_len)?);
        write_out(out, handle_into_raw(doc));
        Ok(OK)
    })
}

/// Small input: loads inline, `out[0]` = the handle, returns `OK`.
/// Big input: copies the bytes, loads on a Rust thread, returns `PENDING`;
/// `done(id, status, handle or error)` reports the end.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_load(
    bytes: *const u8,
    len: i64,
    flags: i32,
    now: *const u8,
    now_len: i64,
    out: *mut i64,
    done: DoneCallback,
    id: i64,
) -> i32 {
    call(|| {
        let input = slice(bytes, len)?;
        let now = slice(now, now_len)?;
        if input.len() < ASYNC_THRESHOLD {
            let doc = load(input, flags, now)?;
            write_out(out, handle_into_raw(doc));
            return Ok(OK);
        }
        let input = input.to_vec();
        let now = now.to_vec();
        spawn(done, id, move || Ok(handle_into_raw(load(&input, flags, &now)?)))
    })
}

/// `out[0]` = a `Bytes` address of the file, or `PENDING` as for load.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_save(handle: *const c_void, flags: i32, out: *mut i64, done: DoneCallback, id: i64) -> i32 {
    call(|| {
        let shared = handle_arc(handle)?;
        let big = estimate_size(&lock(&shared)?.pdf) >= ASYNC_THRESHOLD;
        if !big {
            let bytes = save(&mut *lock(&shared)?, flags)?;
            write_out(out, bytes_into_raw(bytes));
            return Ok(OK);
        }
        spawn(done, id, move || Ok(bytes_into_raw(save(&mut *lock(&shared)?, flags)?)))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_is_encrypted(handle: *const c_void) -> i32 {
    call(|| with_doc(handle, |d| Ok(is_encrypted(&d.pdf) as i32)))
}

/// Writes the page refs into `out` (room for `cap`). Returns the page count;
/// when it is more than `cap`, Dart calls again with more room.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_get_pages(handle: *const c_void, out: *mut i64, cap: i64, count: *mut i64) -> i32 {
    call(|| {
        with_doc(handle, |d| {
            let entries = page_entries(&d.pdf)?;
            write_out(count, entries.len() as i64);
            if entries.len() as i64 <= cap && !out.is_null() {
                for (i, e) in entries.iter().enumerate() {
                    // SAFETY: Dart passes room for `cap` values.
                    unsafe { *out.add(i) = ref_to_i64(e.id) };
                }
            }
            Ok(OK)
        })
    })
}

/// Inserts `page` (a ref), or a new page of `width` x `height` when `page`
/// is 0, at `index`. `out[0]` = the page ref.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_insert_page(
    handle: *const c_void,
    index: i64,
    page: i64,
    width: f64,
    height: f64,
    out: *mut i64,
) -> i32 {
    call(|| {
        with_doc(handle, |d| {
            let count = page_entries(&d.pdf)?.len();
            if index < 0 || index as usize > count {
                return Err(range_error(index.max(0) as usize, count));
            }
            let id = if page == 0 {
                new_page(&mut d.pdf, width, height)
            } else {
                ref_from_i64(page)
            };
            insert_page(&mut d.pdf, index as usize, id)?;
            write_out(out, ref_to_i64(id));
            Ok(OK)
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_remove_page(handle: *const c_void, index: i64) -> i32 {
    call(|| {
        with_doc(handle, |d| {
            let index = usize::try_from(index).unwrap_or(usize::MAX);
            remove_page(&mut d.pdf, index)?;
            Ok(OK)
        })
    })
}

/// Copies the pages at `indices` of `src` into `dst` (not into its page
/// tree). Writes the new page refs into `out` (same length as `indices`).
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_copy_pages(
    dst: *const c_void,
    src: *const c_void,
    indices: *const i64,
    len: i64,
    out: *mut i64,
) -> i32 {
    call(|| {
        if len < 0 || (len > 0 && (indices.is_null() || out.is_null())) {
            return Err(Error::generic("bad input buffer"));
        }
        // SAFETY: Dart passes `len` indices.
        let indices = if len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(indices, len as usize) }
        };
        // read the source first and unlock it, then write the target: the
        // two locks are never held at once (no deadlock, and src may be dst)
        let (objects, pages) = with_doc(src, |s| {
            let entries = page_entries(&s.pdf)?;
            let mut ids = Vec::with_capacity(indices.len());
            for &i in indices {
                let e = usize::try_from(i).ok().and_then(|i| entries.get(i));
                let e = e.ok_or_else(|| range_error(i.max(0) as usize, entries.len().saturating_sub(1)))?;
                ids.push(e.id);
            }
            copy_pages(&s.pdf, &ids)
        })?;
        with_doc(dst, |d| {
            let base = d.pdf.max_id;
            for (id, mut obj) in objects {
                shift(&mut obj, base);
                d.pdf.objects.insert((id + base, 0), obj);
                d.pdf.max_id = d.pdf.max_id.max(id + base);
            }
            for (i, id) in pages.iter().enumerate() {
                // SAFETY: Dart passes room for `len` values.
                unsafe { *out.add(i) = ref_to_i64((id + base, 0)) };
            }
            Ok(OK)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn count(pdf: &Document) -> usize {
        page_entries(pdf).unwrap().len()
    }

    #[test]
    fn create_insert_remove() {
        let mut d = create(false, b"");
        for i in 0..3 {
            let p = new_page(&mut d.pdf, 100.0 + i as f64, 200.0);
            insert_page(&mut d.pdf, i, p).unwrap();
        }
        let first = new_page(&mut d.pdf, 1.0, 1.0);
        insert_page(&mut d.pdf, 0, first).unwrap();
        let ids: Vec<_> = page_entries(&d.pdf).unwrap().iter().map(|e| e.id).collect();
        assert_eq!(ids[0], first);
        assert_eq!(count(&d.pdf), 4);
        remove_page(&mut d.pdf, 0).unwrap();
        assert_eq!(count(&d.pdf), 3);
        assert_eq!(remove_page(&mut d.pdf, 3).unwrap_err().status, ERR_RANGE);
        for _ in 0..3 {
            remove_page(&mut d.pdf, 0).unwrap();
        }
        assert_eq!(remove_page(&mut d.pdf, 0).unwrap_err().status, ERR_EMPTY_REMOVE);
    }

    #[test]
    fn save_adds_a_default_page_and_loads_again() {
        let mut d = create(true, b"D:20200101000000Z");
        let bytes = save(&mut d, SAVE_OBJECT_STREAMS | SAVE_ADD_DEFAULT_PAGE).unwrap();
        let again = load(&bytes, 0, b"").unwrap();
        assert_eq!(count(&again.pdf), 1);
    }

    #[test]
    fn copy_pages_takes_inherited_values() {
        let mut src = create(false, b"");
        let p = new_page(&mut src.pdf, 10.0, 20.0);
        insert_page(&mut src.pdf, 0, p).unwrap();
        // move the MediaBox and a Rotate to the parent
        let root = root_pages(&src.pdf).unwrap();
        let mb = page_dict_mut(&mut src.pdf, p).unwrap().remove(b"MediaBox").unwrap();
        let pages = page_dict_mut(&mut src.pdf, root).unwrap();
        pages.set("MediaBox", mb);
        pages.set("Rotate", Object::Integer(90));
        let (objects, ids) = copy_pages(&src.pdf, &[p, p]).unwrap();
        assert_ne!(ids[0], ids[1]);
        let page = objects
            .iter()
            .find(|(id, _)| *id == ids[0])
            .unwrap()
            .1
            .as_dict()
            .unwrap();
        assert!(page.has(b"MediaBox"));
        assert!(page.has(b"Rotate"));
        assert!(!page.has(b"Parent"));
    }

    #[test]
    fn broken_input_is_an_error() {
        for input in [
            &b""[..],
            b"%PDF-1.7",
            b"%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF",
            &[0xffu8; 1000][..],
        ] {
            assert!(load(input, 0, b"").is_err());
        }
    }

    #[test]
    fn ref_round_trip() {
        assert_eq!(ref_from_i64(ref_to_i64((123456, 7))), (123456, 7));
    }
}
