//! File attachments: pdf-lib's `attach` (`FileEmbedder` and
//! `PDFEmbeddedFile.embed`), and reading them back (an extra: pdf-lib has
//! no getter).

use std::collections::{HashMap, HashSet};
use std::ffi::c_void;

use lopdf::{Dictionary, Document, Object, ObjectId, Stream, StringFormat};

use crate::document::{deref, dict_get};
use crate::draw::deflate;
use crate::ffi_util::*;
use crate::metadata::{decode_text, text_object};

/// Most levels of a name tree we go down when we add a name.
const MAX_DEPTH: usize = 64;

/// Most nodes of the name tree we visit. A broken file can loop.
const MAX_NODES: usize = 100_000;

/// Most bytes all attachments together may decode to in `list`. A hostile
/// file can list one small stream that inflates to gigabytes many times.
const MAX_TOTAL: usize = if cfg!(test) { 1 << 16 } else { 256 << 20 };

/// The values of one attachment to add, but its bytes. Dates are PDF date
/// text (Dart formats them).
#[derive(Default)]
pub struct NewFile {
    pub name: String,
    pub mime_type: Option<String>,
    pub description: Option<String>,
    pub creation_date: Option<String>,
    pub modification_date: Option<String>,
    pub af_relationship: Option<String>,
}

fn name(s: &str) -> Object {
    Object::Name(s.as_bytes().to_vec())
}

fn catalog_id(pdf: &Document) -> Result<ObjectId> {
    match pdf.trailer.get(b"Root") {
        Ok(Object::Reference(id)) => Ok(*id),
        _ => Err(Error::generic("the document has no catalog")),
    }
}

/// pdf-lib's `attach` + `PDFEmbeddedFile.embed`: an `EmbeddedFile` stream,
/// a `Filespec`, a new pair in `/Names /EmbeddedFiles /Names` and a ref in
/// the catalog `/AF`. `compressed` is the file after `deflate`, `size` its
/// length before.
///
/// pdf-lib appends the pair at the end. We insert it sorted by name, as the
/// PDF spec asks for a name tree; readers that search the tree find it.
pub fn attach(pdf: &mut Document, f: &NewFile, size: usize, compressed: Vec<u8>) -> Result<()> {
    let mut params = Dictionary::new();
    params.set("Size", Object::Integer(size as i64));
    if let Some(d) = &f.creation_date {
        params.set("CreationDate", Object::string_literal(d.as_str()));
    }
    if let Some(d) = &f.modification_date {
        params.set("ModDate", Object::string_literal(d.as_str()));
    }
    let mut sd = Dictionary::new();
    sd.set("Type", name("EmbeddedFile"));
    if let Some(m) = &f.mime_type {
        sd.set("Subtype", name(m));
    }
    sd.set("Params", Object::Dictionary(params));
    sd.set("Filter", name("FlateDecode"));
    let stream = pdf.add_object(Stream::new(sd, compressed));

    let mut spec = Dictionary::new();
    spec.set("Type", name("Filespec"));
    // pdf-lib's `PDFString.of(name)` keeps the low byte of each UTF-16 unit
    let latin: Vec<u8> = f.name.encode_utf16().map(|u| u as u8).collect();
    spec.set("F", Object::String(latin, StringFormat::Literal));
    spec.set("UF", text_object(&f.name));
    let mut ef = Dictionary::new();
    ef.set("F", Object::Reference(stream));
    spec.set("EF", Object::Dictionary(ef));
    if let Some(d) = f.description.as_deref().filter(|d| !d.is_empty()) {
        spec.set("Desc", text_object(d));
    }
    if let Some(r) = &f.af_relationship {
        spec.set("AFRelationship", name(r));
    }
    let spec = pdf.add_object(spec);

    let catalog = catalog_id(pdf)?;
    let names = ensure(
        pdf,
        Holder::Object(catalog),
        b"Names",
        Object::Dictionary(Dictionary::new()),
    )?;
    let tree = ensure(pdf, names, b"EmbeddedFiles", Object::Dictionary(Dictionary::new()))?;
    insert_name(pdf, tree, text_object(&f.name), Object::Reference(spec))?;
    let af = ensure(pdf, Holder::Object(catalog), b"AF", Object::Array(vec![]))?;
    array_mut(pdf, &af)?.push(Object::Reference(spec));
    Ok(())
}

/// The key bytes of a name tree key (a direct string).
fn key_of(o: &Object) -> Option<&[u8]> {
    match o {
        Object::String(b, _) => Some(b),
        _ => None,
    }
}

/// `[low, high]` of a tree node's `/Limits`.
fn limits(d: &Dictionary) -> Option<(&[u8], &[u8])> {
    match d.get(b"Limits").ok()? {
        Object::Array(a) if a.len() == 2 => Some((key_of(&a[0])?, key_of(&a[1])?)),
        _ => None,
    }
}

/// Puts `key` -> `value` into the name tree at `tree`, sorted. A tree with
/// `/Kids` gets it in the right leaf (by `/Limits`), and the `/Limits` up
/// the way grow to hold the key: a node has `/Names` or `/Kids`, not both.
fn insert_name(pdf: &mut Document, tree: Holder, key: Object, value: Object) -> Result<()> {
    let key_bytes = key_of(&key).expect("a string key").to_vec();
    let kids_of = |pdf: &Document, d: &Dictionary| -> Vec<ObjectId> {
        match dict_get(pdf, d, b"Kids") {
            Some(Object::Array(a)) => a.iter().filter_map(|k| k.as_reference().ok()).collect(),
            _ => vec![],
        }
    };
    let root = resolve_mut(pdf, &tree)?
        .as_dict()
        .map_err(|_| Error::generic("the name tree is not a dictionary"))?
        .clone();
    let mut kids = kids_of(pdf, &root);
    let mut path: Vec<ObjectId> = Vec::new();
    while !kids.is_empty() && path.len() < MAX_DEPTH {
        // the last kid whose low limit is not above the key, else the first
        let pick = kids
            .iter()
            .rev()
            .find(|k| match pdf.get_dictionary(**k).ok().and_then(limits) {
                Some((low, _)) => low <= key_bytes.as_slice(),
                None => false,
            })
            .or(kids.first())
            .copied()
            .expect("not empty");
        if path.contains(&pick) || pdf.get_dictionary(pick).is_err() {
            break;
        }
        path.push(pick);
        kids = kids_of(pdf, pdf.get_dictionary(pick)?);
    }
    let leaf = match path.last() {
        Some(id) => Holder::Object(*id),
        None => tree,
    };
    let list = ensure(pdf, leaf, b"Names", Object::Array(vec![]))?;
    let list = array_mut(pdf, &list)?;
    // the first pair with a bigger key (byte order); a key that is not a
    // direct string is passed over
    let at = list
        .chunks(2)
        .position(|p| key_of(&p[0]).is_some_and(|b| b > key_bytes.as_slice()))
        .map_or(list.len(), |i| i * 2);
    list.insert(at, value);
    list.insert(at, key.clone());
    for id in path {
        let node = pdf.get_dictionary_mut(id)?;
        let (low, high) = match limits(node) {
            Some((l, h)) => (l.min(&key_bytes).to_vec(), h.max(&key_bytes).to_vec()),
            None => (key_bytes.clone(), key_bytes.clone()),
        };
        let string = |b: Vec<u8>| Object::String(b, StringFormat::Hexadecimal);
        node.set("Limits", Object::Array(vec![string(low), string(high)]));
    }
    Ok(())
}

/// Where a value lives: an object, or a key path inside an object.
#[derive(Clone)]
enum Holder {
    Object(ObjectId),
    Inside(ObjectId, Vec<Vec<u8>>),
}

fn resolve_mut<'a>(pdf: &'a mut Document, h: &Holder) -> Result<&'a mut Object> {
    let broken = || Error::generic("a catalog entry has the wrong type");
    let (id, path) = match h {
        Holder::Object(id) => (*id, &[][..]),
        Holder::Inside(id, path) => (*id, &path[..]),
    };
    let mut obj = pdf.objects.get_mut(&id).ok_or_else(broken)?;
    for k in path {
        obj = obj
            .as_dict_mut()
            .map_err(|_| broken())?
            .get_mut(k)
            .map_err(|_| broken())?;
    }
    Ok(obj)
}

/// pdf-lib's `if (!d.has(key)) d.set(key, value); d.lookup(key)`: the
/// holder of the value at `key`, made when missing.
fn ensure(pdf: &mut Document, h: Holder, key: &[u8], value: Object) -> Result<Holder> {
    let dict = resolve_mut(pdf, &h)?
        .as_dict_mut()
        .map_err(|_| Error::generic("a catalog entry is not a dictionary"))?;
    if !dict.has(key) {
        dict.set(key.to_vec(), value);
    }
    Ok(match dict.get(key)? {
        Object::Reference(r) => Holder::Object(*r),
        _ => match h {
            Holder::Object(id) => Holder::Inside(id, vec![key.to_vec()]),
            Holder::Inside(id, mut path) => {
                path.push(key.to_vec());
                Holder::Inside(id, path)
            }
        },
    })
}

fn array_mut<'a>(pdf: &'a mut Document, h: &Holder) -> Result<&'a mut Vec<Object>> {
    resolve_mut(pdf, h)?
        .as_array_mut()
        .map_err(|_| Error::generic("a catalog entry is not an array"))
}

/// One attachment read back.
#[derive(Debug, Default, PartialEq)]
pub struct File {
    pub name: String,
    pub data: Vec<u8>,
    pub mime_type: Option<String>,
    pub description: Option<String>,
    pub creation_date: Option<String>,
    pub modification_date: Option<String>,
    pub af_relationship: Option<String>,
}

fn text(pdf: &Document, d: &Dictionary, key: &[u8]) -> Option<String> {
    match dict_get(pdf, d, key)? {
        Object::String(b, _) => Some(decode_text(b)),
        _ => None,
    }
}

fn name_text(pdf: &Document, d: &Dictionary, key: &[u8]) -> Option<String> {
    match dict_get(pdf, d, key)? {
        Object::Name(n) => Some(String::from_utf8_lossy(n).into_owned()),
        _ => None,
    }
}

/// All attachments of the `/EmbeddedFiles` name tree, in tree order.
/// Entries that are broken are skipped.
pub fn list(pdf: &Document) -> Result<Vec<File>> {
    let catalog = pdf.get_dictionary(catalog_id(pdf)?)?;
    let Some(Object::Dictionary(names)) = dict_get(pdf, catalog, b"Names") else {
        return Ok(vec![]);
    };
    let Some(Object::Dictionary(root)) = dict_get(pdf, names, b"EmbeddedFiles") else {
        return Ok(vec![]);
    };
    // first all (name, spec) pairs, then the files: so we know which
    // streams are listed more than once (only those are kept for reuse)
    let mut pairs: Vec<(&Object, &Object)> = Vec::new();
    // explicit stack of nodes (in reverse), so a deep tree can not overflow;
    // a node by reference is visited once, so a loop ends
    let mut stack: Vec<&Dictionary> = vec![root];
    let mut visited: HashSet<ObjectId> = HashSet::new();
    let mut nodes = 0;
    while let Some(node) = stack.pop() {
        nodes += 1;
        if nodes > MAX_NODES {
            break;
        }
        if let Some(Object::Array(list)) = dict_get(pdf, node, b"Names") {
            for pair in list.chunks(2) {
                if let [key, spec] = pair {
                    pairs.push((key, spec));
                }
            }
        }
        if let Some(Object::Array(kids)) = dict_get(pdf, node, b"Kids") {
            for kid in kids.iter().rev() {
                if let Object::Reference(id) = kid
                    && !visited.insert(*id)
                {
                    continue;
                }
                if let Some(Object::Dictionary(k)) = deref(pdf, kid) {
                    stack.push(k);
                }
            }
        }
    }
    let mut reader = Reader {
        pdf,
        listed: HashMap::new(),
        decoded: HashMap::new(),
        left: MAX_TOTAL,
    };
    for (_, spec) in &pairs {
        if let Some((Object::Reference(id), _)) = reader.ef_stream(spec) {
            *reader.listed.entry(*id).or_default() += 1;
        }
    }
    Ok(pairs.into_iter().filter_map(|(k, s)| reader.file(k, s)).collect())
}

/// Reads the files of `list` within one byte budget.
struct Reader<'a> {
    pdf: &'a Document,
    /// How many names point at each file stream.
    listed: HashMap<ObjectId, usize>,
    /// Streams decoded before: the bytes (for streams listed more than
    /// once) or `None` when the decode failed. A failed stream is never
    /// decoded again.
    decoded: HashMap<ObjectId, Option<Vec<u8>>>,
    /// Bytes left of `MAX_TOTAL`, for all files read.
    left: usize,
}

impl<'a> Reader<'a> {
    /// The `/EF` stream of a file spec: the raw value (a reference) and the
    /// stream.
    fn ef_stream(&self, spec: &'a Object) -> Option<(&'a Object, &'a Stream)> {
        let pdf = self.pdf;
        let Some(Object::Dictionary(spec)) = deref(pdf, spec) else {
            return None;
        };
        let Some(Object::Dictionary(ef)) = dict_get(pdf, spec, b"EF") else {
            return None;
        };
        let raw = ef.get(b"UF").or_else(|_| ef.get(b"F")).ok()?;
        match deref(pdf, raw) {
            Some(Object::Stream(s)) => Some((raw, s)),
            _ => None,
        }
    }

    fn decode(&mut self, stream: &Stream) -> Option<Vec<u8>> {
        match stream.get_plain_content_with_limit(self.left) {
            Ok(d) => Some(d),
            Err(_) => {
                // a stream over the budget took up to `left` bytes of work;
                // halving what is left keeps all such work below 2x the
                // budget, also with many different hostile streams
                self.left /= 2;
                None
            }
        }
    }

    fn data(&mut self, raw: &Object, stream: &Stream) -> Option<Vec<u8>> {
        let data = match raw {
            Object::Reference(id) => match self.decoded.get(id) {
                Some(None) => return None,
                Some(Some(d)) if d.len() <= self.left => d.clone(),
                Some(Some(_)) => return None,
                None => {
                    let d = self.decode(stream);
                    let many = self.listed.get(id).is_some_and(|n| *n > 1);
                    match &d {
                        None => {
                            self.decoded.insert(*id, None);
                        }
                        Some(d) if many => {
                            self.decoded.insert(*id, Some(d.clone()));
                        }
                        Some(_) => {}
                    }
                    d?
                }
            },
            _ => self.decode(stream)?,
        };
        self.left -= data.len();
        Some(data)
    }

    fn file(&mut self, key: &Object, spec: &'a Object) -> Option<File> {
        let pdf = self.pdf;
        let (raw, stream) = self.ef_stream(spec)?;
        let data = self.data(raw, stream)?;
        let stream_dict = &stream.dict;
        let Some(Object::Dictionary(spec)) = deref(pdf, spec) else {
            return None;
        };
        let key = match deref(pdf, key) {
            Some(Object::String(b, _)) => Some(decode_text(b)),
            _ => None,
        };
        let params = match dict_get(pdf, stream_dict, b"Params") {
            Some(Object::Dictionary(p)) => Some(p),
            _ => None,
        };
        Some(File {
            name: text(pdf, spec, b"UF").or_else(|| text(pdf, spec, b"F")).or(key)?,
            data,
            mime_type: name_text(pdf, stream_dict, b"Subtype"),
            description: text(pdf, spec, b"Desc"),
            creation_date: params.and_then(|p| text(pdf, p, b"CreationDate")),
            modification_date: params.and_then(|p| text(pdf, p, b"ModDate")),
            af_relationship: name_text(pdf, spec, b"AFRelationship"),
        })
    }
}

/// The files as one buffer for Dart: per file 7 fields (name, data, mime
/// type, description, creation date, modification date, AF relationship),
/// each a u32 length (little endian) then the bytes. A missing value has
/// the length 0xFFFFFFFF.
fn encode(files: &[File]) -> Vec<u8> {
    let size: usize = files.iter().map(|f| f.data.len() + f.name.len() + 128).sum();
    let mut out = Vec::with_capacity(size + 4);
    out.extend((files.len() as u32).to_le_bytes());
    let put = |out: &mut Vec<u8>, v: Option<&[u8]>| match v {
        Some(b) => {
            out.extend((b.len() as u32).to_le_bytes());
            out.extend_from_slice(b);
        }
        None => out.extend(u32::MAX.to_le_bytes()),
    };
    for f in files {
        put(&mut out, Some(f.name.as_bytes()));
        put(&mut out, Some(&f.data));
        for v in [
            &f.mime_type,
            &f.description,
            &f.creation_date,
            &f.modification_date,
            &f.af_relationship,
        ] {
            put(&mut out, v.as_deref().map(str::as_bytes));
        }
    }
    out
}

fn utf8_opt(ptr: *const u8, len: i64) -> Result<Option<String>> {
    if len < 0 {
        return Ok(None);
    }
    let bytes = slice(ptr, len)?;
    std::str::from_utf8(bytes)
        .map(|t| Some(t.to_string()))
        .map_err(|_| Error::generic("text is not UTF-8"))
}

/// `texts` = name, mime type, description, creation date, modification
/// date and AF relationship, joined; `lens` = their 6 lengths (-1 = none).
/// Small data: attaches inline, returns `OK`. Data of `ASYNC_THRESHOLD` or
/// more: copies it, compresses it on a Rust thread and returns `PENDING`,
/// like save.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_attach(
    handle: *const c_void,
    data: *const u8,
    data_len: i64,
    texts: *const u8,
    lens: *const i64,
    done: DoneCallback,
    id: i64,
) -> i32 {
    call(|| {
        if lens.is_null() {
            return Err(Error::generic("bad input buffer"));
        }
        // SAFETY: Dart passes 6 lengths.
        let lens = unsafe { std::slice::from_raw_parts(lens, 6) };
        let mut at = 0usize;
        let mut field = |i: usize| -> Result<Option<String>> {
            let len = lens[i];
            // SAFETY: the texts are `sum(lens >= 0)` bytes long.
            let ptr = if texts.is_null() {
                texts
            } else {
                unsafe { texts.add(at) }
            };
            at += len.max(0) as usize;
            utf8_opt(ptr, len)
        };
        let f = NewFile {
            name: field(0)?.unwrap_or_default(),
            mime_type: field(1)?,
            description: field(2)?,
            creation_date: field(3)?,
            modification_date: field(4)?,
            af_relationship: field(5)?,
        };
        let data = slice(data, data_len)?;
        if data.len() < ASYNC_THRESHOLD {
            let compressed = deflate(data)?;
            return with_doc_mut(handle, |d| attach(&mut d.pdf, &f, data.len(), compressed).map(|_| OK));
        }
        let shared = handle_arc(handle)?;
        let data = data.to_vec();
        spawn(done, id, move || {
            let compressed = deflate(&data)?;
            let mut d = lock(&shared)?;
            d.generation = d.generation.wrapping_add(1);
            attach(&mut d.pdf, &f, data.len(), compressed)?;
            Ok(0)
        })
    })
}

/// `out[0]` = a `Bytes` address of the files (see `encode`).
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_get_attachments(handle: *const c_void, out: *mut i64) -> i32 {
    call(|| {
        with_doc(handle, |d| {
            write_out(out, bytes_into_raw(encode(&list(&d.pdf)?)));
            Ok(OK)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::create;

    fn add(pdf: &mut Document, name: &str, data: &[u8]) -> NewFile {
        let f = NewFile {
            name: name.to_string(),
            ..Default::default()
        };
        attach(pdf, &f, data.len(), deflate(data).unwrap()).unwrap();
        f
    }

    #[test]
    fn attach_and_read_back() {
        let mut d = create(false, b"");
        let f = NewFile {
            name: "b.txt".into(),
            mime_type: Some("text/plain".into()),
            description: Some("Grüße".into()),
            creation_date: Some("D:20200101000000Z".into()),
            af_relationship: Some("Data".into()),
            ..Default::default()
        };
        attach(&mut d.pdf, &f, 5, deflate(b"hello").unwrap()).unwrap();
        add(&mut d.pdf, "世界.bin", &[0, 1, 2]);
        add(&mut d.pdf, "a.txt", b"first");
        let files = list(&d.pdf).unwrap();
        // sorted by name (UTF-16 bytes): a.txt, b.txt, 世界.bin
        let names: Vec<&str> = files.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(names, ["a.txt", "b.txt", "世界.bin"]);
        assert_eq!(files[1].data, b"hello");
        assert_eq!(files[1].mime_type.as_deref(), Some("text/plain"));
        assert_eq!(files[1].description.as_deref(), Some("Grüße"));
        assert_eq!(files[1].creation_date.as_deref(), Some("D:20200101000000Z"));
        assert_eq!(files[1].af_relationship.as_deref(), Some("Data"));
        assert_eq!(files[2].data, [0, 1, 2]);
        assert_eq!(files[2].mime_type, None);
        let cat = d.pdf.catalog().unwrap();
        assert_eq!(cat.get(b"AF").unwrap().as_array().unwrap().len(), 3);

        // saved and loaded again
        let bytes = crate::document::save(&mut d, crate::document::SAVE_OBJECT_STREAMS).unwrap();
        let again = crate::document::load(&bytes, 0, b"").unwrap();
        assert_eq!(list(&again.pdf).unwrap(), files);
        assert_eq!(encode(&files)[..4], 3u32.to_le_bytes());
    }

    #[test]
    fn names_by_reference_are_used() {
        let mut d = create(false, b"");
        let tree = d.pdf.add_object(Dictionary::new());
        let mut names = Dictionary::new();
        names.set("EmbeddedFiles", Object::Reference(tree));
        let names = d.pdf.add_object(names);
        let cat = catalog_id(&d.pdf).unwrap();
        d.pdf
            .get_dictionary_mut(cat)
            .unwrap()
            .set("Names", Object::Reference(names));
        add(&mut d.pdf, "x", b"1");
        assert!(d.pdf.get_dictionary(tree).unwrap().has(b"Names"));
        assert_eq!(list(&d.pdf).unwrap().len(), 1);
    }

    #[test]
    fn a_kid_loop_and_a_bomb_listed_many_times_stay_small() {
        let mut d = create(false, b"");
        add(&mut d.pdf, "big", &[b' '; 40 << 10]);
        let cat = catalog_id(&d.pdf).unwrap();
        let tree = match d.pdf.get_dictionary(cat).unwrap().get(b"Names").unwrap() {
            Object::Dictionary(n) => n.get(b"EmbeddedFiles").unwrap().as_dict().unwrap().clone(),
            _ => unreachable!(),
        };
        // the tree as an object whose Kids point back at itself, and whose
        // Names list the same file 100 times
        let pair = tree.get(b"Names").unwrap().as_array().unwrap().clone();
        let id = d.pdf.new_object_id();
        let mut node = Dictionary::new();
        node.set("Names", Object::Array((0..100).flat_map(|_| pair.clone()).collect()));
        node.set("Kids", Object::Array(vec![Object::Reference(id); 3]));
        d.pdf.objects.insert(id, Object::Dictionary(node));
        let mut names = Dictionary::new();
        names.set("EmbeddedFiles", Object::Reference(id));
        d.pdf
            .get_dictionary_mut(cat)
            .unwrap()
            .set("Names", Object::Dictionary(names));
        let files = list(&d.pdf).unwrap();
        // 40 KiB each in a 64 KiB budget (in tests): one file, the node once
        assert_eq!(files.len(), 1);
    }

    #[test]
    fn a_bomb_listed_many_times_is_decoded_once() {
        let mut d = create(false, b"");
        add(&mut d.pdf, "bomb", &vec![b' '; 4 << 20]);
        let cat = catalog_id(&d.pdf).unwrap();
        let names = d.pdf.get_dictionary_mut(cat).unwrap().get_mut(b"Names").unwrap();
        let tree = names.as_dict_mut().unwrap().get_mut(b"EmbeddedFiles").unwrap();
        let list = tree
            .as_dict_mut()
            .unwrap()
            .get_mut(b"Names")
            .unwrap()
            .as_array_mut()
            .unwrap();
        let pair = list.clone();
        for _ in 0..100_000 {
            list.extend(pair.iter().cloned());
        }
        let t = std::time::Instant::now();
        assert!(super::list(&d.pdf).unwrap().is_empty());
        assert!(t.elapsed().as_secs() < 2, "{:?}", t.elapsed());
    }

    #[test]
    fn a_tree_with_kids_gets_the_name_in_a_leaf() {
        let mut d = create(false, b"");
        let leaf = |pdf: &mut Document, names: &[&str]| {
            let mut pairs = vec![];
            for n in names {
                let mut spec = Dictionary::new();
                spec.set("Type", name("Filespec"));
                let mut ef = Dictionary::new();
                let s = pdf.add_object(Stream::new(Dictionary::new(), n.as_bytes().to_vec()));
                ef.set("F", Object::Reference(s));
                spec.set("EF", Object::Dictionary(ef));
                spec.set("UF", text_object(n));
                pairs.push(text_object(n));
                pairs.push(Object::Reference(pdf.add_object(spec)));
            }
            let mut node = Dictionary::new();
            node.set(
                "Limits",
                Object::Array(vec![text_object(names[0]), text_object(names[names.len() - 1])]),
            );
            node.set("Names", Object::Array(pairs));
            pdf.add_object(node)
        };
        let a = leaf(&mut d.pdf, &["b", "d"]);
        let b = leaf(&mut d.pdf, &["m", "p"]);
        let mut root = Dictionary::new();
        root.set("Kids", Object::Array(vec![Object::Reference(a), Object::Reference(b)]));
        let mut names = Dictionary::new();
        names.set("EmbeddedFiles", Object::Dictionary(root));
        let cat = catalog_id(&d.pdf).unwrap();
        d.pdf
            .get_dictionary_mut(cat)
            .unwrap()
            .set("Names", Object::Dictionary(names));
        for n in ["a", "c", "n", "z"] {
            add(&mut d.pdf, n, n.as_bytes());
        }
        let got: Vec<String> = list(&d.pdf).unwrap().into_iter().map(|f| f.name).collect();
        assert_eq!(got, ["a", "b", "c", "d", "m", "n", "p", "z"]);
        let catalog = d.pdf.get_dictionary(cat).unwrap();
        let tree = catalog.get(b"Names").unwrap().as_dict().unwrap();
        let root = tree.get(b"EmbeddedFiles").unwrap().as_dict().unwrap();
        assert!(!root.has(b"Names"), "a root with Kids gets no Names");
        let (low, high) = limits(d.pdf.get_dictionary(a).unwrap()).unwrap();
        assert_eq!(
            (low, high),
            (key_of(&text_object("a")).unwrap(), key_of(&text_object("d")).unwrap())
        );
        let (_, high) = limits(d.pdf.get_dictionary(b).unwrap()).unwrap();
        assert_eq!(high, key_of(&text_object("z")).unwrap());
    }
}
