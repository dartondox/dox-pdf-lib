//! PDF/X and PDF/A: output intents, XMP metadata, the save steps of a
//! standard, and a check of the things the user has to fix.
//!
//! The rules come from ISO 15930 (PDF/X-1a:2003, PDF/X-3:2003, PDF/X-4) and
//! ISO 19005 (PDF/A-1, -2, -3). For PDF/A the rule numbers in comments are
//! the clause numbers that veraPDF uses in its rule list.

use std::collections::HashSet;
use std::ffi::c_void;
use std::hash::{BuildHasher, Hasher};

use lopdf::content::Content;
use lopdf::{Dictionary, Document, Object, ObjectId, Stream, StringFormat};

use crate::document::{as_f64, deref, dict_get, inherited, page_entries};
use crate::ffi_util::*;
use crate::metadata::{decode_text, text_object};

/// Most bytes we decode from one content stream for the check.
const MAX_CONTENT: usize = 64 << 20;

/// The standards, in the order of the Dart enum `PDFStandard`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Standard {
    X1a,
    X3,
    X4,
    A1b,
    A2b,
    A2u,
    A3b,
    A3u,
}

use Standard::*;

impl Standard {
    pub fn from_i32(v: i32) -> Result<Standard> {
        Ok(match v {
            0 => X1a,
            1 => X3,
            2 => X4,
            3 => A1b,
            4 => A2b,
            5 => A2u,
            6 => A3b,
            7 => A3u,
            _ => return Err(Error::generic(format!("unknown standard {v}"))),
        })
    }

    pub fn is_x(self) -> bool {
        matches!(self, X1a | X3 | X4)
    }

    /// The PDF/A part, or None for PDF/X.
    fn a_part(self) -> Option<u8> {
        match self {
            A1b => Some(1),
            A2b | A2u => Some(2),
            A3b | A3u => Some(3),
            _ => None,
        }
    }

    fn a_level(self) -> &'static str {
        if matches!(self, A2u | A3u) { "U" } else { "B" }
    }

    fn name(self) -> &'static str {
        match self {
            X1a => "PDF/X-1a",
            X3 => "PDF/X-3",
            X4 => "PDF/X-4",
            A1b => "PDF/A-1b",
            A2b => "PDF/A-2b",
            A2u => "PDF/A-2u",
            A3b => "PDF/A-3b",
            A3u => "PDF/A-3u",
        }
    }

    /// The highest PDF version the standard allows. We write this version.
    pub fn version(self) -> &'static str {
        match self {
            X1a | X3 | A1b => "1.4",
            X4 => "1.6",
            _ => "1.7",
        }
    }

    /// PDF/X-4, PDF/A-2 and PDF/A-3 allow transparency.
    fn transparency(self) -> bool {
        matches!(self, X4 | A2b | A2u | A3b | A3u)
    }

    fn subtype(self) -> &'static [u8] {
        if self.is_x() { b"GTS_PDFX" } else { b"GTS_PDFA1" }
    }

    /// The Info `/GTS_PDFXVersion` text.
    fn pdfx_version(self) -> &'static str {
        match self {
            X1a => "PDF/X-1:2003",
            X3 => "PDF/X-3:2003",
            _ => "PDF/X-4",
        }
    }
}

/// The conformance state of a document. Part of `Doc`.
#[derive(Clone, Default)]
pub struct State {
    pub standard: Option<Standard>,
    /// The user set their own XMP; save keeps it.
    pub own_xmp: bool,
}

// ------------------------------------------------------------- ICC profiles

/// What we read from an ICC profile header.
#[derive(Debug, PartialEq)]
pub struct Icc {
    /// Color components: 1 gray, 3 RGB, 4 CMYK.
    pub n: i64,
    /// The device class, eg. `prtr` (output) or `mntr` (display).
    pub class: [u8; 4],
    pub major: u8,
}

/// Checks the 128 byte header of an ICC profile (ICC.1, 7.2).
pub fn read_icc(bytes: &[u8]) -> Result<Icc> {
    if bytes.len() < 132 {
        return Err(Error::generic(format!(
            "the ICC profile is too short ({} bytes); a profile has at least a 128 byte header and a tag table",
            bytes.len()
        )));
    }
    if &bytes[36..40] != b"acsp" {
        return Err(Error::generic(
            "this is not an ICC profile: the header has no 'acsp' signature",
        ));
    }
    let size = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;
    if size > bytes.len() {
        return Err(Error::generic(format!(
            "the ICC profile is cut off: the header says {size} bytes, but there are {}",
            bytes.len()
        )));
    }
    let n = match &bytes[16..20] {
        b"GRAY" => 1,
        b"RGB " => 3,
        b"CMYK" => 4,
        other => {
            return Err(Error::generic(format!(
                "the ICC profile is for the color space '{}'; only Gray, RGB and CMYK profiles can be an output intent",
                String::from_utf8_lossy(other).trim_end()
            )));
        }
    };
    let class = [bytes[12], bytes[13], bytes[14], bytes[15]];
    if &class != b"prtr" && &class != b"mntr" {
        return Err(Error::generic(format!(
            "the ICC profile has the device class '{}'; an output intent needs an output (prtr) or display (mntr) profile",
            String::from_utf8_lossy(&class)
        )));
    }
    Ok(Icc {
        n,
        class,
        major: bytes[8],
    })
}

// ------------------------------------------------------------ output intents

/// The texts of an output intent. Empty means not set.
pub struct Intent<'a> {
    pub subtype: &'a [u8],
    pub identifier: &'a str,
    pub condition: &'a str,
    pub registry: &'a str,
    pub info: &'a str,
}

/// A text string: plain when it is printable ASCII, else UTF-16.
fn pdf_text(s: &str) -> Object {
    if s.bytes().all(|b| (0x20..0x7f).contains(&b)) {
        Object::String(s.as_bytes().to_vec(), StringFormat::Literal)
    } else {
        text_object(s)
    }
}

fn catalog_id(pdf: &Document) -> Result<ObjectId> {
    match pdf.trailer.get(b"Root") {
        Ok(Object::Reference(id)) => Ok(*id),
        _ => Err(Error::generic("the document has no catalog")),
    }
}

fn catalog(pdf: &Document) -> Result<&Dictionary> {
    Ok(pdf.get_dictionary(catalog_id(pdf)?)?)
}

/// The output intent dicts of the catalog.
fn intents(pdf: &Document) -> Vec<&Dictionary> {
    let Ok(cat) = catalog(pdf) else { return vec![] };
    match dict_get(pdf, cat, b"OutputIntents") {
        Some(Object::Array(items)) => items
            .iter()
            .filter_map(|i| match deref(pdf, i) {
                Some(Object::Dictionary(d)) => Some(d),
                _ => None,
            })
            .collect(),
        _ => vec![],
    }
}

/// Adds an output intent. With `replace`, intents of the same subtype go
/// first. A profile that is already in another intent is shared: PDF/A-2
/// asks that all intents use the same profile object (6.2.3).
pub fn add_intent(pdf: &mut Document, icc: &[u8], intent: &Intent, replace: bool) -> Result<()> {
    let info = read_icc(icc)?;
    if intent.identifier.is_empty() {
        return Err(Error::generic("the output condition identifier must not be empty"));
    }
    if intent.subtype == b"GTS_PDFX" && &info.class != b"prtr" {
        return Err(Error::generic(
            "PDF/X needs an output (printer) ICC profile, device class 'prtr'",
        ));
    }
    let packed = crate::draw::deflate(icc)?;
    let cat_id = catalog_id(pdf)?;
    let mut list: Vec<Object> = match dict_get(pdf, catalog(pdf)?, b"OutputIntents") {
        Some(Object::Array(items)) => items.clone(),
        _ => vec![],
    };
    if replace {
        list.retain(|i| match deref(pdf, i) {
            Some(Object::Dictionary(d)) => !matches!(d.get(b"S"), Ok(Object::Name(n)) if n == intent.subtype),
            _ => false,
        });
    }
    // share a profile stream with the same bytes
    let same = list.iter().find_map(|i| {
        let Some(Object::Dictionary(d)) = deref(pdf, i) else {
            return None;
        };
        let Ok(Object::Reference(r)) = d.get(b"DestOutputProfile") else {
            return None;
        };
        match pdf.objects.get(r) {
            Some(Object::Stream(s)) if s.content == packed => Some(*r),
            _ => None,
        }
    });
    let profile = match same {
        Some(r) => r,
        None => {
            let mut d = Dictionary::new();
            d.set("N", Object::Integer(info.n));
            d.set("Filter", Object::Name(b"FlateDecode".to_vec()));
            pdf.add_object(Stream::new(d, packed))
        }
    };
    let mut d = Dictionary::new();
    d.set("Type", Object::Name(b"OutputIntent".to_vec()));
    d.set("S", Object::Name(intent.subtype.to_vec()));
    d.set("OutputConditionIdentifier", pdf_text(intent.identifier));
    for (key, value) in [
        ("OutputCondition", intent.condition),
        ("RegistryName", intent.registry),
        ("Info", intent.info),
    ] {
        if !value.is_empty() {
            d.set(key, pdf_text(value));
        }
    }
    d.set("DestOutputProfile", Object::Reference(profile));
    list.push(Object::Reference(pdf.add_object(d)));
    pdf.get_dictionary_mut(cat_id)?
        .set("OutputIntents", Object::Array(list));
    Ok(())
}

/// `setConformance`: the output intent now, the rest at save.
pub fn set(doc: &mut Doc, standard: Standard, icc: &[u8], intent: &Intent) -> Result<()> {
    let info = read_icc(icc)?;
    if standard == X1a && info.n == 3 {
        return Err(Error::generic(
            "PDF/X-1a needs a CMYK or gray output profile, not an RGB one",
        ));
    }
    if standard.version() == "1.4" && info.major >= 4 {
        return Err(Error::generic(format!(
            "{} is based on PDF 1.4, which reads ICC profiles of version 2 only; this profile is version {}",
            standard.name(),
            info.major
        )));
    }
    let intent = Intent {
        subtype: standard.subtype(),
        ..*intent
    };
    add_intent(&mut doc.pdf, icc, &intent, true)?;
    doc.conformance.standard = Some(standard);
    Ok(())
}

// --------------------------------------------------------------------- XMP

/// The catalog `/Metadata` stream as text.
pub fn get_xmp(pdf: &Document) -> Result<Option<String>> {
    let Some(Object::Stream(s)) = dict_get(pdf, catalog(pdf)?, b"Metadata") else {
        return Ok(None);
    };
    let bytes = s.get_plain_content_with_limit(MAX_CONTENT)?;
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
}

/// Sets the catalog `/Metadata` stream, not compressed (PDF/A-1 6.7.2 has
/// no filter on it; readers that are not PDF aware can find it).
pub fn set_xmp(pdf: &mut Document, xml: &str) -> Result<()> {
    let mut d = Dictionary::new();
    d.set("Type", Object::Name(b"Metadata".to_vec()));
    d.set("Subtype", Object::Name(b"XML".to_vec()));
    let stream = Object::Stream(Stream::new(d, xml.as_bytes().to_vec()));
    let cat_id = catalog_id(pdf)?;
    match pdf.get_dictionary(cat_id)?.get(b"Metadata") {
        Ok(Object::Reference(r)) if matches!(pdf.objects.get(r), Some(Object::Stream(_))) => {
            let r = *r;
            pdf.objects.insert(r, stream);
        }
        _ => {
            let r = pdf.add_object(stream);
            pdf.get_dictionary_mut(cat_id)?.set("Metadata", Object::Reference(r));
        }
    }
    Ok(())
}

/// XML text: escapes the five special characters and drops the control
/// characters that XML 1.0 does not allow.
fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            '\t' | '\n' | '\r' => out.push(c),
            c if (c as u32) < 0x20 || c == '\u{FFFE}' || c == '\u{FFFF}' => {}
            c => out.push(c),
        }
    }
    out
}

/// A PDF date (`D:YYYYMMDDHHmmSSOHH'mm'`) as an XMP date
/// (`YYYY-MM-DDThh:mm:ss+hh:mm`), with the same time zone, so PDF/A
/// readers see the same time in both (PDF/A-1 6.7.3).
pub fn xmp_date(pdf_date: &str) -> Option<String> {
    let s = pdf_date.strip_prefix("D:").unwrap_or(pdf_date);
    let digits: String = s.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.len() < 4 || !digits.len().is_multiple_of(2) || digits.len() > 14 {
        return None;
    }
    let part = |i: usize, fallback: &str| digits.get(i..i + 2).unwrap_or(fallback).to_string();
    let mut out = format!(
        "{}-{}-{}T{}:{}:{}",
        &digits[0..4],
        part(4, "01"),
        part(6, "01"),
        part(8, "00"),
        part(10, "00"),
        part(12, "00")
    );
    let rest = &s[digits.len()..];
    match rest.chars().next() {
        Some('Z') => out.push('Z'),
        Some(sign @ ('+' | '-')) => {
            let tz: String = rest[1..].chars().filter(|c| c.is_ascii_digit()).collect();
            let hh = tz.get(0..2)?;
            let mm = tz.get(2..4).unwrap_or("00");
            out.push_str(&format!("{sign}{hh}:{mm}"));
        }
        // no time zone: an XMP date may have none too
        _ => {}
    }
    Some(out)
}

fn info_dict(pdf: &Document) -> Option<&Dictionary> {
    match deref(pdf, pdf.trailer.get(b"Info").ok()?)? {
        Object::Dictionary(d) => Some(d),
        _ => None,
    }
}

fn info_text(pdf: &Document, key: &[u8]) -> Option<String> {
    match dict_get(pdf, info_dict(pdf)?, key)? {
        Object::String(b, _) => Some(decode_text(b)),
        Object::Name(n) => Some(String::from_utf8_lossy(n).into_owned()),
        _ => None,
    }
}

/// The first and second part of the trailer `/ID`.
fn file_id(pdf: &Document) -> Option<(Vec<u8>, Vec<u8>)> {
    match pdf.trailer.get(b"ID").ok().and_then(|o| deref(pdf, o)) {
        Some(Object::Array(a)) => match (
            a.first().and_then(|o| deref(pdf, o)),
            a.get(1).and_then(|o| deref(pdf, o)),
        ) {
            (Some(Object::String(x, _)), Some(Object::String(y, _))) if !x.is_empty() && !y.is_empty() => {
                Some((x.clone(), y.clone()))
            }
            _ => None,
        },
        _ => None,
    }
}

/// 16 bytes that are new on each call. The hasher keys of `RandomState`
/// come from the OS, and the time makes each call different.
fn random_id() -> Vec<u8> {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut out = Vec::with_capacity(16);
    for i in 0..2u8 {
        let mut h = std::collections::hash_map::RandomState::new().build_hasher();
        h.write_u128(nanos);
        h.write_u8(i);
        out.extend_from_slice(&h.finish().to_le_bytes());
    }
    out
}

fn uuid(bytes: &[u8]) -> String {
    let hex: String = bytes.iter().take(16).map(|b| format!("{b:02x}")).collect();
    let hex = format!("{hex:0<32}");
    format!(
        "uuid:{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// The trailer `/ID`: a file keeps its first part; the second part is new
/// on each save (PDF 32000-1, 14.4).
pub fn ensure_id(pdf: &mut Document) {
    let first = file_id(pdf).map(|(a, _)| a).unwrap_or_else(random_id);
    let second = random_id();
    pdf.trailer.set(
        "ID",
        Object::Array(vec![
            Object::String(first, StringFormat::Hexadecimal),
            Object::String(second, StringFormat::Hexadecimal),
        ]),
    );
}

/// XMP metadata from the Info dict, with the identification schema of
/// `standard`. Info and XMP must say the same (PDF/A-1 6.7.3, PDF/A-2 and
/// -3 6.6.2.3), so this runs at save, after all set calls.
pub fn make_xmp(pdf: &Document, standard: Option<Standard>) -> String {
    let text = |k: &[u8]| info_text(pdf, k).map(|t| xml_escape(&t));
    let date = |k: &[u8]| info_text(pdf, k).and_then(|t| xmp_date(&t));
    let mut x = String::new();
    x.push_str("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
    x.push_str("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n");
    x.push_str("<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");

    x.push_str("<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n");
    x.push_str("<dc:format>application/pdf</dc:format>\n");
    if let Some(t) = text(b"Title") {
        x.push_str(&format!(
            "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">{t}</rdf:li></rdf:Alt></dc:title>\n"
        ));
    }
    if let Some(t) = text(b"Author") {
        x.push_str(&format!(
            "<dc:creator><rdf:Seq><rdf:li>{t}</rdf:li></rdf:Seq></dc:creator>\n"
        ));
    }
    if let Some(t) = text(b"Subject") {
        x.push_str(&format!(
            "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">{t}</rdf:li></rdf:Alt></dc:description>\n"
        ));
    }
    x.push_str("</rdf:Description>\n");

    x.push_str("<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\">\n");
    if let Some(t) = text(b"Creator") {
        x.push_str(&format!("<xmp:CreatorTool>{t}</xmp:CreatorTool>\n"));
    }
    let created = date(b"CreationDate");
    let modified = date(b"ModDate");
    if let Some(d) = &created {
        x.push_str(&format!("<xmp:CreateDate>{d}</xmp:CreateDate>\n"));
    }
    if let Some(d) = &modified {
        x.push_str(&format!("<xmp:ModifyDate>{d}</xmp:ModifyDate>\n"));
    }
    if let Some(d) = modified.as_ref().or(created.as_ref()) {
        x.push_str(&format!("<xmp:MetadataDate>{d}</xmp:MetadataDate>\n"));
    }
    x.push_str("</rdf:Description>\n");

    x.push_str("<rdf:Description rdf:about=\"\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\">\n");
    if let Some(t) = text(b"Producer") {
        x.push_str(&format!("<pdf:Producer>{t}</pdf:Producer>\n"));
    }
    if let Some(t) = text(b"Keywords") {
        x.push_str(&format!("<pdf:Keywords>{t}</pdf:Keywords>\n"));
    }
    if let Some(t) = text(b"Trapped") {
        x.push_str(&format!("<pdf:Trapped>{t}</pdf:Trapped>\n"));
    }
    x.push_str("</rdf:Description>\n");

    let (doc_id, instance_id) = file_id(pdf).unwrap_or_else(|| (random_id(), random_id()));
    x.push_str("<rdf:Description rdf:about=\"\" xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\">\n");
    x.push_str(&format!("<xmpMM:DocumentID>{}</xmpMM:DocumentID>\n", uuid(&doc_id)));
    // PDF/A-1 knows the xmpMM schema of 2004, without InstanceID
    if standard != Some(A1b) {
        x.push_str(&format!(
            "<xmpMM:InstanceID>{}</xmpMM:InstanceID>\n",
            uuid(&instance_id)
        ));
    }
    // PDF/X-4 asks for both (ISO 15930-7, 6.7.2)
    if standard.is_some_and(Standard::is_x) {
        x.push_str("<xmpMM:VersionID>1</xmpMM:VersionID>\n");
        x.push_str("<xmpMM:RenditionClass>default</xmpMM:RenditionClass>\n");
    }
    x.push_str("</rdf:Description>\n");

    match standard {
        Some(s @ (A1b | A2b | A2u | A3b | A3u)) => {
            x.push_str("<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\">\n");
            x.push_str(&format!("<pdfaid:part>{}</pdfaid:part>\n", s.a_part().unwrap_or(0)));
            x.push_str(&format!("<pdfaid:conformance>{}</pdfaid:conformance>\n", s.a_level()));
            x.push_str("</rdf:Description>\n");
        }
        Some(X4) => {
            x.push_str("<rdf:Description rdf:about=\"\" xmlns:pdfxid=\"http://www.npes.org/pdfx/ns/id/\">\n");
            x.push_str("<pdfxid:GTS_PDFXVersion>PDF/X-4</pdfxid:GTS_PDFXVersion>\n");
            x.push_str("</rdf:Description>\n");
        }
        Some(s @ (X1a | X3)) => {
            x.push_str("<rdf:Description rdf:about=\"\" xmlns:pdfx=\"http://ns.adobe.com/pdfx/1.3/\">\n");
            x.push_str(&format!(
                "<pdfx:GTS_PDFXVersion>{}</pdfx:GTS_PDFXVersion>\n",
                s.pdfx_version()
            ));
            if s == X1a {
                x.push_str("<pdfx:GTS_PDFXConformance>PDF/X-1a:2003</pdfx:GTS_PDFXConformance>\n");
            }
            x.push_str("</rdf:Description>\n");
        }
        None => {}
    }
    x.push_str("</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>");
    x
}

// -------------------------------------------------------------------- save

/// The save steps of the standard. Runs on the copy that save writes, so
/// the document itself does not change. Clears `SAVE_OBJECT_STREAMS` for a
/// standard based on PDF 1.4, which has no object streams.
pub fn before_save(state: &State, pdf: &mut Document, flags: &mut i32) -> Result<()> {
    let Some(standard) = state.standard else {
        return Ok(());
    };
    pdf.version = standard.version().to_string();
    if standard.version() < "1.5" {
        *flags &= !crate::document::SAVE_OBJECT_STREAMS;
    }
    // PDF/X: `/Trapped` must be True or False; we do not trap, so False
    // when the user did not say (ISO 15930-4, 6.6.1)
    if standard.is_x() {
        let info = info_mut(pdf);
        if !matches!(info.get(b"Trapped"), Ok(Object::Name(n)) if n == b"True" || n == b"False") {
            info.set("Trapped", Object::Name(b"False".to_vec()));
        }
        info.set("GTS_PDFXVersion", pdf_text(standard.pdfx_version()));
        if standard == X1a {
            info.set("GTS_PDFXConformance", pdf_text("PDF/X-1a:2003"));
        }
    }
    if standard.a_part().is_some() {
        fix_annotations(pdf);
    }
    ensure_id(pdf);
    if !state.own_xmp {
        let xml = make_xmp(pdf, Some(standard));
        set_xmp(pdf, &xml)?;
    }
    Ok(())
}

fn info_mut(pdf: &mut Document) -> &mut Dictionary {
    let id = match pdf.trailer.get(b"Info") {
        Ok(Object::Reference(r)) if matches!(pdf.objects.get(r), Some(Object::Dictionary(_))) => *r,
        _ => {
            let r = pdf.add_object(Dictionary::new());
            pdf.trailer.set("Info", Object::Reference(r));
            r
        }
    };
    match pdf.objects.get_mut(&id) {
        Some(Object::Dictionary(d)) => d,
        _ => unreachable!("checked above"),
    }
}

/// PDF/A: an appearance dict has only `/N` (PDF/A-2 6.3.3), and the form
/// has no `/NeedAppearances true` (6.4.1). Save made the appearances.
fn fix_annotations(pdf: &mut Document) {
    let aps: Vec<ObjectId> = pdf
        .objects
        .iter()
        .filter_map(|(id, o)| match o {
            Object::Dictionary(d) if d.has(b"Subtype") && d.has(b"Rect") && d.has(b"AP") => Some(*id),
            _ => None,
        })
        .collect();
    for id in aps {
        let ap_ref = match pdf.objects.get_mut(&id) {
            Some(Object::Dictionary(d)) => match d.get_mut(b"AP") {
                Ok(Object::Dictionary(ap)) => {
                    ap.remove(b"D");
                    ap.remove(b"R");
                    None
                }
                Ok(Object::Reference(r)) => Some(*r),
                _ => None,
            },
            _ => None,
        };
        if let Some(Object::Dictionary(ap)) = ap_ref.and_then(|r| pdf.objects.get_mut(&r)) {
            ap.remove(b"D");
            ap.remove(b"R");
        }
    }
    let Ok(cat_id) = catalog_id(pdf) else { return };
    let form = match pdf.get_dictionary(cat_id).ok().and_then(|c| c.get(b"AcroForm").ok()) {
        Some(Object::Reference(r)) => Some(*r),
        _ => None,
    };
    let form = match form {
        Some(r) => pdf.objects.get_mut(&r).and_then(|o| o.as_dict_mut().ok()),
        None => pdf
            .get_dictionary_mut(cat_id)
            .ok()
            .and_then(|c| c.get_mut(b"AcroForm").ok())
            .and_then(|o| o.as_dict_mut().ok()),
    };
    if let Some(f) = form {
        f.remove(b"NeedAppearances");
    }
}

// ------------------------------------------------------------------- check

/// The kinds of issues, in the order of the Dart enum `ConformanceIssueKind`.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Kind {
    FontNotEmbedded = 0,
    FontNoUnicode = 1,
    Transparency = 2,
    Color = 3,
    PageBox = 4,
    Encryption = 5,
    EmbeddedFile = 6,
    Action = 7,
    FileId = 8,
    Metadata = 9,
    Version = 10,
    OutputIntent = 11,
    Info = 12,
    Annotation = 13,
    Other = 14,
}

#[derive(Debug, PartialEq)]
pub struct Issue {
    pub kind: Kind,
    /// The page index (from 0), or None for the document.
    pub page: Option<usize>,
    pub message: String,
}

/// Color spaces used, for the color rules.
#[derive(Default)]
struct Colors {
    rgb: bool,
    cmyk: bool,
    /// ICC based, Lab or calibrated colors
    independent: bool,
}

struct Checker<'a> {
    pdf: &'a Document,
    standard: Standard,
    issues: Vec<Issue>,
    seen: HashSet<(Kind, String)>,
    /// objects already checked (fonts, images, forms, resources)
    done: HashSet<ObjectId>,
}

impl Checker<'_> {
    /// Adds an issue once per document (the first page that has it).
    fn add(&mut self, kind: Kind, page: Option<usize>, message: String) {
        if self.seen.insert((kind, message.clone())) {
            self.issues.push(Issue { kind, page, message });
        }
    }

    fn is_a(&self) -> bool {
        self.standard.a_part().is_some()
    }

    fn colors(&mut self, page: Option<usize>, c: &Colors, oi: i64) {
        let s = self.standard.name();
        if c.rgb {
            if self.standard == X1a {
                self.add(
                    Kind::Color,
                    page,
                    "RGB colors are used. PDF/X-1a allows only CMYK, gray and spot colors: use cmyk() and CMYK images."
                        .into(),
                );
            } else if oi != 3 {
                self.add(
                    Kind::Color,
                    page,
                    format!("device RGB colors are used, but the {s} output intent is not RGB. Use CMYK colors, or an RGB output profile."),
                );
            }
        }
        if c.cmyk && oi != 4 {
            self.add(
                Kind::Color,
                page,
                format!("device CMYK colors are used, but the {s} output intent is not CMYK. Use RGB colors, or a CMYK output profile."),
            );
        }
        if c.independent && self.standard == X1a {
            self.add(
                Kind::Color,
                page,
                "ICC based, calibrated or Lab colors are used. PDF/X-1a allows only CMYK, gray and spot colors.".into(),
            );
        }
    }

    fn transparency(&mut self, page: Option<usize>, what: &str) {
        if !self.standard.transparency() {
            let s = self.standard.name();
            self.add(
                Kind::Transparency,
                page,
                format!("{what}. {s} does not allow transparency: draw with opacity 1, and use images without alpha."),
            );
        }
    }
}

/// Adds the device color spaces of a color space object to `c`.
fn classify(pdf: &Document, obj: &Object, res: Option<&Dictionary>, c: &mut Colors, depth: usize) {
    if depth > 8 {
        return;
    }
    let Some(obj) = deref(pdf, obj) else { return };
    match obj {
        Object::Name(n) => match n.as_slice() {
            b"DeviceRGB" | b"RGB" => c.rgb = true,
            b"DeviceCMYK" | b"CMYK" => c.cmyk = true,
            b"DeviceGray" | b"G" | b"Pattern" => {}
            // a name of the /ColorSpace resources
            other => {
                if let Some(Object::Dictionary(spaces)) = res.and_then(|r| dict_get(pdf, r, b"ColorSpace"))
                    && let Ok(v) = spaces.get(other)
                {
                    classify(pdf, v, None, c, depth + 1);
                }
            }
        },
        Object::Array(a) => {
            let family = a.first().and_then(|o| deref(pdf, o)).and_then(|o| o.as_name().ok());
            match family {
                Some(b"ICCBased" | b"CalRGB" | b"CalGray" | b"Lab" | b"CalCMYK") => c.independent = true,
                Some(b"Indexed" | b"I" | b"Pattern") => {
                    if let Some(base) = a.get(1) {
                        classify(pdf, base, res, c, depth + 1);
                    }
                }
                Some(b"Separation") => {
                    if let Some(alt) = a.get(2) {
                        classify(pdf, alt, res, c, depth + 1);
                    }
                }
                Some(b"DeviceN") => {
                    if let Some(alt) = a.get(2) {
                        classify(pdf, alt, res, c, depth + 1);
                    }
                }
                Some(_) => classify(pdf, &a[0], res, c, depth + 1),
                None => {}
            }
        }
        _ => {}
    }
}

/// The color space of the output intent: 1, 3, 4, or 0 when there is none.
fn intent_components(pdf: &Document, subtype: &[u8]) -> i64 {
    for d in intents(pdf) {
        if !matches!(d.get(b"S"), Ok(Object::Name(n)) if n == subtype) {
            continue;
        }
        if let Some(Object::Stream(s)) = dict_get(pdf, d, b"DestOutputProfile") {
            if let Ok(bytes) = s.get_plain_content_with_limit(MAX_CONTENT)
                && let Ok(icc) = read_icc(&bytes)
            {
                return icc.n;
            }
            if let Some(n) = dict_get(pdf, &s.dict, b"N").and_then(as_f64) {
                return n as i64;
            }
        }
        // a registered condition without a profile (PDF/X): CMYK print
        return 4;
    }
    0
}

const BLEND_MODES: [&[u8]; 16] = [
    b"Normal",
    b"Compatible",
    b"Multiply",
    b"Screen",
    b"Overlay",
    b"Darken",
    b"Lighten",
    b"ColorDodge",
    b"ColorBurn",
    b"HardLight",
    b"SoftLight",
    b"Difference",
    b"Exclusion",
    b"Hue",
    b"Saturation",
    b"Color",
];

/// One content stream with its resources: a page, a form XObject or an
/// appearance stream.
struct Job<'a> {
    content: Vec<u8>,
    res: Option<&'a Dictionary>,
}

fn check_ext_g_state(ck: &mut Checker, page: Option<usize>, gs: &Dictionary) {
    let pdf = ck.pdf;
    for key in [&b"CA"[..], b"ca"] {
        if dict_get(pdf, gs, key).and_then(as_f64).is_some_and(|v| v < 1.0) {
            ck.transparency(page, "opacity below 1 is used");
        }
    }
    if let Some(m) = dict_get(pdf, gs, b"SMask")
        && !matches!(m, Object::Name(n) if n == b"None")
    {
        ck.transparency(page, "a soft mask is used");
    }
    match dict_get(pdf, gs, b"BM") {
        Some(Object::Name(n)) if n != b"Normal" && n != b"Compatible" => {
            if BLEND_MODES.contains(&n.as_slice()) {
                ck.transparency(page, "a blend mode other than Normal is used");
            } else {
                ck.add(
                    Kind::Transparency,
                    page,
                    format!(
                        "the blend mode {} is not a standard PDF blend mode",
                        String::from_utf8_lossy(n)
                    ),
                );
            }
        }
        Some(Object::Array(_)) => ck.transparency(page, "a blend mode list is used"),
        _ => {}
    }
    // transfer functions and halftones change the printed colors (PDF/X
    // and PDF/A: TR, TR2, HTP)
    if gs.has(b"TR") || matches!(dict_get(pdf, gs, b"TR2"), Some(o) if !matches!(o, Object::Name(n) if n == b"Default"))
    {
        ck.add(
            Kind::Other,
            page,
            "a graphics state has a transfer function (TR or TR2), which this standard does not allow".into(),
        );
    }
}

fn check_font(ck: &mut Checker, page: Option<usize>, font: &Dictionary) {
    let pdf = ck.pdf;
    let name = match dict_get(pdf, font, b"BaseFont") {
        Some(Object::Name(n)) => String::from_utf8_lossy(n).into_owned(),
        _ => "(no name)".into(),
    };
    let subtype = dict_get(pdf, font, b"Subtype")
        .and_then(|o| o.as_name().ok())
        .unwrap_or(b"");
    if subtype == b"Type3" {
        return;
    }
    let descriptor_of = |f: &Dictionary| match dict_get(pdf, f, b"FontDescriptor") {
        Some(Object::Dictionary(d)) => Some(d.clone()),
        _ => None,
    };
    let desc = if subtype == b"Type0" {
        match dict_get(pdf, font, b"DescendantFonts") {
            Some(Object::Array(a)) => match a.first().and_then(|o| deref(pdf, o)) {
                Some(Object::Dictionary(d)) => descriptor_of(d),
                _ => None,
            },
            _ => None,
        }
    } else {
        descriptor_of(font)
    };
    let embedded = desc
        .as_ref()
        .is_some_and(|d| d.has(b"FontFile") || d.has(b"FontFile2") || d.has(b"FontFile3"));
    if !embedded {
        let s = ck.standard.name();
        ck.add(
            Kind::FontNotEmbedded,
            page,
            format!(
                "the font {name} is not embedded. {s} needs every font in the file: use embedFont with a font file, not a standard font."
            ),
        );
    }
    // PDF/A-2u and -3u: every font maps to Unicode (6.2.11.7.2). A simple
    // font with a named encoding maps by its glyph names.
    if matches!(ck.standard, A2u | A3u) && !font.has(b"ToUnicode") {
        let named = subtype != b"Type0" && font.has(b"Encoding");
        if !named {
            ck.add(
                Kind::FontNoUnicode,
                page,
                format!("the font {name} has no ToUnicode map, so its text can not be copied as Unicode"),
            );
        }
    }
}

/// Checks a resource dict and pushes its form XObjects as new jobs.
fn check_resources<'a>(
    ck: &mut Checker<'a>,
    page: Option<usize>,
    res: &'a Dictionary,
    colors: &mut Colors,
    jobs: &mut Vec<Job<'a>>,
) {
    let pdf = ck.pdf;
    let entries = |key: &[u8]| -> Vec<(Option<ObjectId>, &'a Object)> {
        match dict_get(pdf, res, key) {
            Some(Object::Dictionary(d)) => d
                .iter()
                .map(|(_, v)| match v {
                    Object::Reference(r) => (Some(*r), deref(pdf, v).unwrap_or(&Object::Null)),
                    _ => (None, v),
                })
                .collect(),
            _ => vec![],
        }
    };
    for (id, f) in entries(b"Font") {
        if id.is_some_and(|id| !ck.done.insert(id)) {
            continue;
        }
        if let Object::Dictionary(f) = f {
            check_font(ck, page, f);
        }
    }
    for (_, gs) in entries(b"ExtGState") {
        if let Object::Dictionary(gs) = gs {
            check_ext_g_state(ck, page, gs);
        }
    }
    for (_, cs) in entries(b"ColorSpace") {
        classify(pdf, cs, None, colors, 0);
    }
    for (_, sh) in entries(b"Shading") {
        let dict = match sh {
            Object::Dictionary(d) => Some(d),
            Object::Stream(s) => Some(&s.dict),
            _ => None,
        };
        if let Some(cs) = dict.and_then(|d| d.get(b"ColorSpace").ok()) {
            classify(pdf, cs, None, colors, 0);
        }
    }
    for (id, x) in entries(b"XObject") {
        if id.is_some_and(|id| !ck.done.insert(id)) {
            continue;
        }
        let Object::Stream(s) = x else { continue };
        check_xobject(ck, page, s, colors, jobs);
    }
}

fn check_xobject<'a>(
    ck: &mut Checker<'a>,
    page: Option<usize>,
    s: &'a Stream,
    colors: &mut Colors,
    jobs: &mut Vec<Job<'a>>,
) {
    let pdf = ck.pdf;
    let d = &s.dict;
    let old = ck.standard.version() == "1.4";
    match dict_get(pdf, d, b"Subtype").and_then(|o| o.as_name().ok()) {
        Some(b"Image") => {
            if d.has(b"SMask") {
                ck.transparency(page, "an image has an alpha channel (soft mask), eg. a PNG with alpha");
            }
            if !matches!(dict_get(pdf, d, b"ImageMask"), Some(Object::Boolean(true)))
                && let Ok(cs) = d.get(b"ColorSpace")
            {
                classify(pdf, cs, None, colors, 0);
            }
            if matches!(dict_get(pdf, d, b"Interpolate"), Some(Object::Boolean(true))) && ck.is_a() {
                ck.add(
                    Kind::Other,
                    page,
                    "an image has Interpolate true, which PDF/A does not allow".into(),
                );
            }
            if d.has(b"Alternates") || d.has(b"OPI") {
                ck.add(
                    Kind::Other,
                    page,
                    "an image has Alternates or OPI, which this standard does not allow".into(),
                );
            }
            if old {
                if dict_get(pdf, d, b"BitsPerComponent").and_then(as_f64) == Some(16.0) {
                    ck.add(
                        Kind::Version,
                        page,
                        "an image has 16 bits per component, which needs PDF 1.5; use 8 bit images".into(),
                    );
                }
                let jpx = match dict_get(pdf, d, b"Filter") {
                    Some(Object::Name(n)) => n == b"JPXDecode",
                    Some(Object::Array(a)) => a.iter().any(|f| matches!(f, Object::Name(n) if n == b"JPXDecode")),
                    _ => false,
                };
                if jpx {
                    ck.add(Kind::Version, page, "a JPEG 2000 image needs PDF 1.5".into());
                }
            }
        }
        Some(b"Form") => {
            if is_transparency_group(pdf, d) {
                ck.transparency(page, "a form XObject is a transparency group");
            }
            if d.has(b"OPI") {
                ck.add(
                    Kind::Other,
                    page,
                    "a form XObject has OPI, which this standard does not allow".into(),
                );
            }
            let res = match dict_get(pdf, d, b"Resources") {
                Some(Object::Dictionary(r)) => Some(r),
                _ => None,
            };
            if let Ok(content) = s.get_plain_content_with_limit(MAX_CONTENT) {
                jobs.push(Job { content, res });
            }
        }
        Some(b"PS") => ck.add(Kind::Other, page, "a PostScript XObject is used".into()),
        _ => {}
    }
}

fn is_transparency_group(pdf: &Document, d: &Dictionary) -> bool {
    match dict_get(pdf, d, b"Group") {
        Some(Object::Dictionary(g)) => matches!(dict_get(pdf, g, b"S"), Some(Object::Name(n)) if n == b"Transparency"),
        _ => false,
    }
}

/// Runs the content streams of a page (and the forms they use).
fn run_jobs<'a>(ck: &mut Checker<'a>, page: Option<usize>, mut jobs: Vec<Job<'a>>, colors: &mut Colors) {
    let mut checked_res: HashSet<*const Dictionary> = HashSet::new();
    let mut runs = 0;
    while let Some(job) = jobs.pop() {
        runs += 1;
        if runs > 10_000 {
            break;
        }
        if let Some(res) = job.res
            && checked_res.insert(res as *const _)
        {
            check_resources(ck, page, res, colors, &mut jobs);
        }
        // ponytail: inline images (BI ... EI) are not checked; pdf-lib does
        // not write them
        for op in Content::decode_iter(&job.content) {
            let Ok(op) = op else { break };
            match op.operator.as_str() {
                "rg" | "RG" => colors.rgb = true,
                "k" | "K" => colors.cmyk = true,
                "cs" | "CS" => {
                    if let Some(name) = op.operands.first() {
                        classify(ck.pdf, name, job.res, colors, 0);
                    }
                }
                _ => {}
            }
        }
    }
}

/// The action types PDF/A allows (PDF/A-1 6.6.1, PDF/A-2 6.5.1).
fn check_action(ck: &mut Checker, page: Option<usize>, action: Option<&Object>, depth: usize) {
    let pdf = ck.pdf;
    let Some(Object::Dictionary(a)) = action.and_then(|a| deref(pdf, a)) else {
        return;
    };
    if depth > 8 {
        return;
    }
    let s = dict_get(pdf, a, b"S").and_then(|o| o.as_name().ok()).unwrap_or(b"");
    if s == b"JavaScript" {
        ck.add(
            Kind::Action,
            page,
            "a JavaScript action is used; this standard does not allow JavaScript".into(),
        );
    } else if ck.is_a() {
        let banned = matches!(
            s,
            b"Launch"
                | b"Sound"
                | b"Movie"
                | b"ResetForm"
                | b"ImportData"
                | b"Hide"
                | b"SetOCGState"
                | b"Rendition"
                | b"Trans"
                | b"GoTo3DView"
        );
        let bad_named = s == b"Named"
            && !matches!(
                dict_get(pdf, a, b"N").and_then(|o| o.as_name().ok()),
                Some(b"NextPage" | b"PrevPage" | b"FirstPage" | b"LastPage")
            );
        if banned || bad_named {
            ck.add(
                Kind::Action,
                page,
                format!(
                    "a {} action is used, which PDF/A does not allow",
                    String::from_utf8_lossy(s)
                ),
            );
        }
    }
    // the next actions of a chain
    match dict_get(pdf, a, b"Next") {
        Some(Object::Array(list)) => {
            for n in list {
                check_action(ck, page, Some(n), depth + 1);
            }
        }
        Some(n @ Object::Dictionary(_)) => check_action(ck, page, Some(n), depth + 1),
        _ => {}
    }
}

fn rect_of(pdf: &Document, obj: Option<&Object>) -> Option<[f64; 4]> {
    let Some(Object::Array(a)) = obj.and_then(|o| deref(pdf, o)) else {
        return None;
    };
    if a.len() != 4 {
        return None;
    }
    let mut v = [0.0; 4];
    for (i, o) in a.iter().enumerate() {
        v[i] = deref(pdf, o).and_then(as_f64)?;
    }
    Some([v[0].min(v[2]), v[1].min(v[3]), v[0].max(v[2]), v[1].max(v[3])])
}

fn check_annotations<'a>(
    ck: &mut Checker<'a>,
    page: usize,
    pd: &'a Dictionary,
    trim: Option<[f64; 4]>,
    jobs: &mut Vec<Job<'a>>,
) {
    let pdf = ck.pdf;
    let Some(Object::Array(annots)) = dict_get(pdf, pd, b"Annots") else {
        return;
    };
    let p = Some(page);
    for a in annots {
        let Some(Object::Dictionary(a)) = deref(pdf, a) else {
            continue;
        };
        let subtype = dict_get(pdf, a, b"Subtype")
            .and_then(|o| o.as_name().ok())
            .unwrap_or(b"");
        let label = String::from_utf8_lossy(subtype).into_owned();
        let rect = rect_of(pdf, a.get(b"Rect").ok());
        check_action(ck, p, a.get(b"A").ok(), 0);
        if ck.is_a() {
            let flags = dict_get(pdf, a, b"F").and_then(as_f64).unwrap_or(0.0) as i64;
            // 6.5.3 (A-1), 6.3.2 (A-2): printed, not hidden
            if subtype != b"Popup" && (flags & 4 == 0 || flags & (1 | 2 | 32 | 256) != 0) {
                ck.add(
                    Kind::Annotation,
                    p,
                    format!(
                        "a {label} annotation is hidden or not printed; PDF/A needs the Print flag and no Hidden flag"
                    ),
                );
            }
            let banned = match subtype {
                b"Sound" | b"Movie" | b"Screen" | b"3D" | b"RichMedia" => true,
                b"FileAttachment" => ck.standard == A1b,
                _ => false,
            };
            if banned {
                ck.add(
                    Kind::Annotation,
                    p,
                    format!("a {label} annotation is used, which PDF/A does not allow"),
                );
            }
            let empty = rect.is_some_and(|r| r[2] - r[0] == 0.0 && r[3] - r[1] == 0.0);
            if ck.standard != A1b && !a.has(b"AP") && !matches!(subtype, b"Popup" | b"Link") && !empty {
                ck.add(
                    Kind::Annotation,
                    p,
                    format!("a {label} annotation has no appearance stream"),
                );
            }
            if a.has(b"AA") {
                ck.add(
                    Kind::Action,
                    p,
                    "an annotation or form field has additional actions (AA)".into(),
                );
            }
        }
        if ck.standard.is_x()
            && !matches!(subtype, b"PrinterMark" | b"TrapNet")
            && let (Some(r), Some(t)) = (rect, trim)
            && r[0] < t[2]
            && r[2] > t[0]
            && r[1] < t[3]
            && r[3] > t[1]
        {
            ck.add(
                Kind::Annotation,
                p,
                format!("a {label} annotation is inside the trim box; PDF/X allows only printer marks there"),
            );
        }
        // the normal appearance is content too
        if let Some(Object::Dictionary(ap)) = dict_get(pdf, a, b"AP") {
            match dict_get(pdf, ap, b"N") {
                Some(Object::Stream(s)) => push_form(pdf, s, jobs, ck),
                Some(Object::Dictionary(states)) => {
                    for (_, v) in states.iter() {
                        if let Some(Object::Stream(s)) = deref(pdf, v) {
                            push_form(pdf, s, jobs, ck);
                        }
                    }
                }
                _ => {}
            }
        }
    }
}

fn push_form<'a>(pdf: &'a Document, s: &'a Stream, jobs: &mut Vec<Job<'a>>, ck: &mut Checker<'a>) {
    if is_transparency_group(pdf, &s.dict) {
        ck.transparency(None, "an annotation appearance is a transparency group");
    }
    let res = match dict_get(pdf, &s.dict, b"Resources") {
        Some(Object::Dictionary(r)) => Some(r),
        _ => None,
    };
    if let Ok(content) = s.get_plain_content_with_limit(MAX_CONTENT) {
        jobs.push(Job { content, res });
    }
}

fn check_pages(ck: &mut Checker) -> Result<()> {
    let pdf = ck.pdf;
    let oi = intent_components(pdf, ck.standard.subtype());
    for (i, entry) in page_entries(pdf)?.iter().enumerate() {
        let Ok(pd) = pdf.get_dictionary(entry.id) else { continue };
        let p = Some(i);
        let mut colors = Colors::default();
        let mut jobs: Vec<Job> = Vec::new();
        let res = match inherited(pdf, pd, b"Resources") {
            Some(Object::Dictionary(r)) => Some(r),
            _ => None,
        };
        if let Ok(content) = pdf.get_page_content_with_limit(entry.id, MAX_CONTENT) {
            jobs.push(Job { content, res });
        }
        if is_transparency_group(pdf, pd) {
            ck.transparency(p, "the page is a transparency group");
        }
        if let Some(Object::Dictionary(g)) = dict_get(pdf, pd, b"Group")
            && let Ok(cs) = g.get(b"CS")
        {
            classify(pdf, cs, res, &mut colors, 0);
        }
        let trim = rect_of(pdf, pd.get(b"TrimBox").ok()).or_else(|| rect_of(pdf, pd.get(b"ArtBox").ok()));
        if ck.standard.is_x() {
            check_boxes(ck, i, pd);
        }
        if ck.is_a() && pd.has(b"AA") {
            ck.add(
                Kind::Action,
                p,
                "the page has additional actions (AA), which PDF/A does not allow".into(),
            );
        }
        check_annotations(ck, i, pd, trim, &mut jobs);
        run_jobs(ck, p, jobs, &mut colors);
        ck.colors(p, &colors, oi);
    }
    Ok(())
}

/// PDF/X: a TrimBox or ArtBox on each page, inside the BleedBox and the
/// MediaBox (ISO 15930-4, 6.1.1).
fn check_boxes(ck: &mut Checker, page: usize, pd: &Dictionary) {
    let pdf = ck.pdf;
    let p = Some(page);
    let trim = rect_of(pdf, pd.get(b"TrimBox").ok());
    let art = rect_of(pdf, pd.get(b"ArtBox").ok());
    let Some(t) = trim.or(art) else {
        ck.add(
            Kind::PageBox,
            p,
            "the page has no TrimBox (or ArtBox). PDF/X needs one on every page: use page.setTrimBox().".into(),
        );
        return;
    };
    let inside = |outer: Option<[f64; 4]>| {
        outer.is_none_or(|o| t[0] >= o[0] - 0.01 && t[1] >= o[1] - 0.01 && t[2] <= o[2] + 0.01 && t[3] <= o[3] + 0.01)
    };
    if !inside(rect_of(pdf, inherited(pdf, pd, b"MediaBox"))) || !inside(rect_of(pdf, pd.get(b"BleedBox").ok())) {
        ck.add(
            Kind::PageBox,
            p,
            "the TrimBox (or ArtBox) is not inside the MediaBox and the BleedBox".into(),
        );
    }
}

fn check_document(ck: &mut Checker) -> Result<()> {
    let pdf = ck.pdf;
    let s = ck.standard;
    let name = s.name();
    let cat = catalog(pdf)?;

    // version: the header of the saved file
    if pdf.version.as_str() > s.version() {
        ck.add(
            Kind::Version,
            None,
            format!(
                "the PDF version is {}, but {name} allows at most {}",
                pdf.version,
                s.version()
            ),
        );
    }
    if crate::document::is_encrypted(pdf) && pdf.trailer.has(b"Encrypt") {
        ck.add(
            Kind::Encryption,
            None,
            format!("the file is encrypted; {name} does not allow encryption"),
        );
    }
    if file_id(pdf).is_none() {
        ck.add(Kind::FileId, None, "the file has no /ID in its trailer".into());
    }

    // the output intent
    let ours: Vec<&Dictionary> = intents(pdf)
        .into_iter()
        .filter(|d| matches!(d.get(b"S"), Ok(Object::Name(n)) if n == s.subtype()))
        .collect();
    match ours.first() {
        None => ck.add(
            Kind::OutputIntent,
            None,
            format!(
                "the file has no {} output intent; use setConformance or addOutputIntent",
                String::from_utf8_lossy(s.subtype())
            ),
        ),
        Some(d) => {
            let profile = dict_get(pdf, d, b"DestOutputProfile");
            if profile.is_none() && (!s.is_x() || !d.has(b"RegistryName")) {
                ck.add(
                    Kind::OutputIntent,
                    None,
                    "the output intent has no ICC profile (DestOutputProfile)".into(),
                );
            }
            if let Some(Object::Stream(st)) = profile
                && let Ok(bytes) = st.get_plain_content_with_limit(MAX_CONTENT)
            {
                match read_icc(&bytes) {
                    Err(e) => ck.add(
                        Kind::OutputIntent,
                        None,
                        format!("the output intent profile is broken: {}", e.message),
                    ),
                    Ok(icc) => {
                        if s == X1a && icc.n == 3 {
                            ck.add(
                                Kind::OutputIntent,
                                None,
                                "PDF/X-1a needs a CMYK output profile, not RGB".into(),
                            );
                        }
                        if s.is_x() && &icc.class != b"prtr" {
                            ck.add(
                                Kind::OutputIntent,
                                None,
                                "PDF/X needs an output (prtr) ICC profile".into(),
                            );
                        }
                        if s.version() == "1.4" && icc.major >= 4 {
                            ck.add(
                                Kind::OutputIntent,
                                None,
                                format!("{name} needs an ICC profile of version 2"),
                            );
                        }
                    }
                }
            }
        }
    }
    // PDF/A-2 6.2.3: all output intents share one profile
    let profiles: HashSet<String> = intents(pdf)
        .iter()
        .filter_map(|d| d.get(b"DestOutputProfile").ok().map(|p| format!("{p:?}")))
        .collect();
    if ck.is_a() && profiles.len() > 1 {
        ck.add(
            Kind::OutputIntent,
            None,
            "the output intents use different ICC profiles".into(),
        );
    }

    // XMP
    let xmp_obj = dict_get(pdf, cat, b"Metadata");
    let xmp = get_xmp(pdf).ok().flatten();
    match &xmp {
        None if ck.is_a() || s == X4 => {
            ck.add(Kind::Metadata, None, "the file has no XMP metadata".into());
        }
        Some(x) => {
            if let Some(part) = s.a_part() {
                let ok_part = x.contains(&format!("<pdfaid:part>{part}</pdfaid:part>"))
                    || x.contains(&format!("pdfaid:part=\"{part}\""));
                let level = s.a_level();
                let ok_level = x.contains(&format!("<pdfaid:conformance>{level}</pdfaid:conformance>"))
                    || x.contains(&format!("pdfaid:conformance=\"{level}\""));
                if !ok_part || !ok_level {
                    ck.add(
                        Kind::Metadata,
                        None,
                        format!("the XMP metadata does not say {name} (pdfaid:part and pdfaid:conformance)"),
                    );
                }
            }
            if s == X4 && !x.contains("PDF/X-4") {
                ck.add(
                    Kind::Metadata,
                    None,
                    "the XMP metadata does not say PDF/X-4 (pdfxid:GTS_PDFXVersion)".into(),
                );
            }
            if s == A1b && matches!(xmp_obj, Some(Object::Stream(st)) if st.dict.has(b"Filter")) {
                ck.add(
                    Kind::Metadata,
                    None,
                    "the XMP metadata stream is compressed; PDF/A-1 needs it plain".into(),
                );
            }
        }
        None => {}
    }

    // Info (PDF/X)
    if s.is_x() {
        if info_text(pdf, b"Title").is_none_or(|t| t.is_empty()) {
            ck.add(
                Kind::Info,
                None,
                "the document has no title; PDF/X needs one: use setTitle()".into(),
            );
        }
        for (key, what) in [
            (&b"CreationDate"[..], "creation date"),
            (b"ModDate", "modification date"),
        ] {
            if info_text(pdf, key).is_none() {
                ck.add(Kind::Info, None, format!("the document has no {what}; PDF/X needs one"));
            }
        }
        if !matches!(info_text(pdf, b"Trapped").as_deref(), Some("True" | "False")) {
            ck.add(
                Kind::Info,
                None,
                "the Trapped key must be True or False in PDF/X: use setTrapped()".into(),
            );
        }
        if matches!(s, X1a | X3) && info_text(pdf, b"GTS_PDFXVersion").is_none() {
            ck.add(Kind::Info, None, "the Info dict has no GTS_PDFXVersion".into());
        }
    }

    // actions and JavaScript
    if let Some(Object::Dictionary(names)) = dict_get(pdf, cat, b"Names")
        && names.has(b"JavaScript")
    {
        ck.add(
            Kind::Action,
            None,
            "the document has JavaScript; this standard does not allow it".into(),
        );
    }
    check_action(ck, None, cat.get(b"OpenAction").ok(), 0);
    if ck.is_a() && cat.has(b"AA") {
        ck.add(
            Kind::Action,
            None,
            "the document has additional actions (AA), which PDF/A does not allow".into(),
        );
    }
    if let Some(Object::Dictionary(form)) = dict_get(pdf, cat, b"AcroForm")
        && ck.is_a()
    {
        if matches!(dict_get(pdf, form, b"NeedAppearances"), Some(Object::Boolean(true))) {
            ck.add(
                Kind::Annotation,
                None,
                "the form has NeedAppearances true; PDF/A needs saved appearances".into(),
            );
        }
        if form.has(b"XFA") {
            ck.add(
                Kind::Other,
                None,
                "the form is an XFA form, which PDF/A does not allow".into(),
            );
        }
    }
    if s == A1b && cat.has(b"OCProperties") {
        ck.add(
            Kind::Other,
            None,
            "the document has optional content (layers), which PDF/A-1 does not allow".into(),
        );
    }

    // attachments
    for f in crate::attachment::list(pdf).unwrap_or_default() {
        match s {
            A1b => ck.add(
                Kind::EmbeddedFile,
                None,
                format!("the file {} is attached; PDF/A-1 does not allow attachments", f.name),
            ),
            A2b | A2u if !f.data.starts_with(b"%PDF") => ck.add(
                Kind::EmbeddedFile,
                None,
                format!(
                    "the file {} is attached, but PDF/A-2 allows only PDF/A files as attachments; use PDF/A-3",
                    f.name
                ),
            ),
            A3b | A3u => {
                if f.af_relationship.is_none() {
                    ck.add(
                        Kind::EmbeddedFile,
                        None,
                        format!(
                            "the attachment {} has no AFRelationship; pass afRelationship to attach()",
                            f.name
                        ),
                    );
                }
                if f.mime_type.is_none() {
                    ck.add(
                        Kind::EmbeddedFile,
                        None,
                        format!("the attachment {} has no MIME type; pass mimeType to attach()", f.name),
                    );
                }
            }
            _ => {}
        }
    }

    // stream filters (PDF/A: no LZW, no external file streams)
    if ck.is_a() {
        for o in pdf.objects.values() {
            let Object::Stream(st) = o else { continue };
            let lzw = match st.dict.get(b"Filter") {
                Ok(Object::Name(n)) => n == b"LZWDecode",
                Ok(Object::Array(a)) => a.iter().any(|f| matches!(f, Object::Name(n) if n == b"LZWDecode")),
                _ => false,
            };
            if lzw {
                ck.add(
                    Kind::Other,
                    None,
                    "a stream uses the LZW filter, which PDF/A does not allow".into(),
                );
            }
            if st.dict.has(b"F") || st.dict.has(b"FFilter") {
                ck.add(
                    Kind::Other,
                    None,
                    "a stream refers to an external file, which PDF/A does not allow".into(),
                );
            }
        }
    }
    Ok(())
}

/// The issues of the file as save would write it.
pub fn check(doc: &Doc, standard: Standard) -> Result<Vec<Issue>> {
    let mut copy = doc.clone();
    let mut flags = crate::document::SAVE_ADD_DEFAULT_PAGE | crate::document::SAVE_UPDATE_FIELD_APPEARANCES;
    // with the save steps of the standard set by setConformance, if any
    let pdf = crate::document::prepare_save(&mut copy, &mut flags)?;
    let mut ck = Checker {
        pdf: &pdf,
        standard,
        issues: vec![],
        seen: HashSet::new(),
        done: HashSet::new(),
    };
    check_pages(&mut ck)?;
    check_document(&mut ck)?;
    Ok(ck.issues)
}

// ----------------------------------------------------------------- exports

/// Reads the 4 texts of an intent: UTF-8, joined, with their lengths.
fn texts<'a>(bytes: &'a [u8], lengths: &[i64]) -> Result<Vec<&'a str>> {
    let mut out = Vec::with_capacity(lengths.len());
    let mut at = 0usize;
    for &len in lengths {
        let len = usize::try_from(len).map_err(|_| Error::generic("bad text length"))?;
        let part = bytes
            .get(at..at + len)
            .ok_or_else(|| Error::generic("bad text length"))?;
        out.push(std::str::from_utf8(part).map_err(|_| Error::generic("text is not UTF-8"))?);
        at += len;
    }
    Ok(out)
}

fn intent_args<'a>(texts_ptr: *const u8, texts_len: i64, lengths: *const i64) -> Result<[&'a str; 4]> {
    let lens = slice(lengths as *const u8, 32)?;
    let lens: Vec<i64> = lens.as_chunks::<8>().0.iter().map(|c| i64::from_ne_bytes(*c)).collect();
    let t = texts(slice(texts_ptr, texts_len)?, &lens)?;
    Ok([t[0], t[1], t[2], t[3]])
}

/// `subtype` 0 = GTS_PDFX, 1 = GTS_PDFA1. `texts` = identifier, condition,
/// registry and info (UTF-8, joined), `lengths` = their 4 lengths.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_conf_add_intent(
    handle: *const c_void,
    icc: *const u8,
    icc_len: i64,
    subtype: i32,
    texts_ptr: *const u8,
    texts_len: i64,
    lengths: *const i64,
) -> i32 {
    call(|| {
        let icc = slice(icc, icc_len)?;
        let [identifier, condition, registry, info] = intent_args(texts_ptr, texts_len, lengths)?;
        let subtype: &[u8] = match subtype {
            0 => b"GTS_PDFX",
            1 => b"GTS_PDFA1",
            _ => return Err(Error::generic(format!("unknown output intent subtype {subtype}"))),
        };
        let intent = Intent {
            subtype,
            identifier,
            condition,
            registry,
            info,
        };
        with_doc_mut(handle, |d| add_intent(&mut d.pdf, icc, &intent, false).map(|_| OK))
    })
}

/// `setConformance`. `texts` and `lengths` as in `dox_pdf_conf_add_intent`.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_conf_set(
    handle: *const c_void,
    standard: i32,
    icc: *const u8,
    icc_len: i64,
    texts_ptr: *const u8,
    texts_len: i64,
    lengths: *const i64,
) -> i32 {
    call(|| {
        let standard = Standard::from_i32(standard)?;
        let icc = slice(icc, icc_len)?;
        let [identifier, condition, registry, info] = intent_args(texts_ptr, texts_len, lengths)?;
        let intent = Intent {
            subtype: b"",
            identifier,
            condition,
            registry,
            info,
        };
        with_doc_mut(handle, |d| set(d, standard, icc, &intent).map(|_| OK))
    })
}

/// `out[0]` = a `Bytes` address (UTF-8), or `ERR_NOT_FOUND` when unset.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_conf_get_xmp(handle: *const c_void, out: *mut i64) -> i32 {
    call(|| {
        with_doc(handle, |d| match get_xmp(&d.pdf)? {
            Some(x) => {
                write_out(out, bytes_into_raw(x.into_bytes()));
                Ok(OK)
            }
            None => Ok(ERR_NOT_FOUND),
        })
    })
}

/// Sets the user's own XMP; save keeps it.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_conf_set_xmp(handle: *const c_void, xml: *const u8, xml_len: i64) -> i32 {
    call(|| {
        let xml = std::str::from_utf8(slice(xml, xml_len)?).map_err(|_| Error::generic("the XMP text is not UTF-8"))?;
        if !xml.contains("<rdf:RDF") && !xml.contains(":RDF") {
            return Err(Error::generic("the XMP text has no rdf:RDF element"));
        }
        with_doc_mut(handle, |d| {
            set_xmp(&mut d.pdf, xml)?;
            d.conformance.own_xmp = true;
            Ok(OK)
        })
    })
}

/// XMP from the Info dict. `standard` -1 = no identification schema.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_conf_make_xmp(handle: *const c_void, standard: i32, out: *mut i64) -> i32 {
    call(|| {
        let standard = if standard < 0 {
            None
        } else {
            Some(Standard::from_i32(standard)?)
        };
        with_doc(handle, |d| {
            write_out(out, bytes_into_raw(make_xmp(&d.pdf, standard).into_bytes()));
            Ok(OK)
        })
    })
}

/// `out[0]` = a `Bytes` address: per issue `kind \t page \t message \n`,
/// page -1 for the document.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_conf_check(handle: *const c_void, standard: i32, out: *mut i64) -> i32 {
    call(|| {
        let standard = Standard::from_i32(standard)?;
        let issues = with_doc(handle, |d| check(d, standard))?;
        let mut text = String::new();
        for i in issues {
            let page = i.page.map_or(-1, |p| p as i64);
            text.push_str(&format!(
                "{}\t{}\t{}\n",
                i.kind as i32,
                page,
                i.message.replace(['\t', '\n'], " ")
            ));
        }
        write_out(out, bytes_into_raw(text.into_bytes()));
        Ok(OK)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::{SAVE_ADD_DEFAULT_PAGE, SAVE_OBJECT_STREAMS, create, save};
    use crate::metadata::{MODE_LITERAL, MODE_TEXT, set as meta_set};

    fn header(space: &[u8; 4], class: &[u8; 4]) -> Vec<u8> {
        let mut b = vec![0u8; 132];
        b[0..4].copy_from_slice(&132u32.to_be_bytes());
        b[8] = 2;
        b[12..16].copy_from_slice(class);
        b[16..20].copy_from_slice(space);
        b[36..40].copy_from_slice(b"acsp");
        b
    }

    fn intent() -> Intent<'static> {
        Intent {
            subtype: b"",
            identifier: "Test",
            condition: "",
            registry: "",
            info: "",
        }
    }

    /// Every start tag has its end tag.
    fn well_formed(xml: &str) -> bool {
        let mut stack: Vec<&str> = Vec::new();
        let mut rest = xml;
        while let Some(i) = rest.find('<') {
            let end = rest[i..].find('>').map(|e| i + e).unwrap();
            let tag = &rest[i + 1..end];
            rest = &rest[end + 1..];
            if tag.starts_with('?') || tag.ends_with('/') {
                continue;
            }
            let name = tag.trim_start_matches('/').split_whitespace().next().unwrap();
            if tag.starts_with('/') {
                if stack.pop() != Some(name) {
                    return false;
                }
            } else {
                stack.push(name);
            }
        }
        stack.is_empty()
    }

    #[test]
    fn icc_header() {
        let icc = read_icc(&header(b"CMYK", b"prtr")).unwrap();
        assert_eq!((icc.n, &icc.class, icc.major), (4, b"prtr", 2));
        assert_eq!(read_icc(&header(b"GRAY", b"mntr")).unwrap().n, 1);
        assert!(read_icc(&[0; 50]).unwrap_err().message.contains("too short"));
        let mut b = header(b"RGB ", b"mntr");
        b[36] = b'x';
        assert!(read_icc(&b).unwrap_err().message.contains("acsp"));
        let mut b = header(b"RGB ", b"mntr");
        b[0..4].copy_from_slice(&5000u32.to_be_bytes());
        assert!(read_icc(&b).unwrap_err().message.contains("cut off"));
        assert!(read_icc(&header(b"Lab ", b"mntr")).is_err());
        assert!(read_icc(&header(b"RGB ", b"scnr")).is_err());
    }

    #[test]
    fn dates() {
        assert_eq!(xmp_date("D:20260102030405Z").unwrap(), "2026-01-02T03:04:05Z");
        assert_eq!(
            xmp_date("D:20260102030405+05'30'").unwrap(),
            "2026-01-02T03:04:05+05:30"
        );
        assert_eq!(xmp_date("D:2026").unwrap(), "2026-01-01T00:00:00");
        assert_eq!(xmp_date("D:20260102030405-08'00").unwrap(), "2026-01-02T03:04:05-08:00");
        assert_eq!(xmp_date("nonsense"), None);
        assert_eq!(xmp_date("D:202"), None);
    }

    #[test]
    fn xmp_escapes_and_is_well_formed() {
        let mut d = create(true, b"D:20260101000000Z");
        meta_set(&mut d.pdf, b"Title", "a<b>&\"'\u{1}c", MODE_TEXT).unwrap();
        meta_set(&mut d.pdf, b"Trapped", "False", crate::metadata::MODE_NAME).unwrap();
        for s in [None, Some(X1a), Some(X3), Some(X4), Some(A1b), Some(A2u), Some(A3b)] {
            let x = make_xmp(&d.pdf, s);
            assert!(well_formed(&x), "{x}");
            assert!(x.contains("a&lt;b&gt;&amp;&quot;&apos;c"));
            assert!(x.contains("<pdf:Trapped>False</pdf:Trapped>"));
            assert_eq!(x.contains("xmpMM:InstanceID"), s != Some(A1b));
        }
        assert!(make_xmp(&d.pdf, Some(A3b)).contains("<pdfaid:part>3</pdfaid:part>"));
        assert!(make_xmp(&d.pdf, Some(X1a)).contains("PDF/X-1a:2003"));
    }

    #[test]
    fn save_steps() {
        let mut d = create(true, b"D:20260101000000Z");
        set(&mut d, X1a, &header(b"CMYK", b"prtr"), &intent()).unwrap();
        let out = save(&mut d, SAVE_ADD_DEFAULT_PAGE | SAVE_OBJECT_STREAMS).unwrap();
        let text = String::from_utf8_lossy(&out);
        assert!(text.starts_with("%PDF-1.4"));
        assert!(!text.contains("/ObjStm"));
        assert!(text.contains("/Trapped/False"));
        assert!(text.contains("/GTS_PDFXVersion(PDF/X-1:2003)"));
        assert!(text.contains("/ID["));
        // the document itself is not changed by save
        assert!(!d.pdf.trailer.has(b"ID"));
        // an RGB profile does not fit PDF/X-1a; a v4 profile not PDF/A-1
        assert!(set(&mut d, X1a, &header(b"RGB ", b"prtr"), &intent()).is_err());
        let mut v4 = header(b"RGB ", b"mntr");
        v4[8] = 4;
        assert!(set(&mut d, A1b, &v4, &intent()).is_err());
        assert!(set(&mut d, A2b, &v4, &intent()).is_ok());
    }

    #[test]
    fn intents_share_one_profile_and_replace() {
        let mut d = create(true, b"");
        let icc = header(b"RGB ", b"mntr");
        set(&mut d, A2b, &icc, &intent()).unwrap();
        set(&mut d, A2b, &icc, &intent()).unwrap();
        assert_eq!(intents(&d.pdf).len(), 1);
        let a = Intent {
            subtype: b"ISO_PDFE1",
            ..intent()
        };
        add_intent(&mut d.pdf, &icc, &a, false).unwrap();
        let list = intents(&d.pdf);
        assert_eq!(list.len(), 2);
        assert_eq!(
            list[0].get(b"DestOutputProfile").unwrap(),
            list[1].get(b"DestOutputProfile").unwrap()
        );
    }

    #[test]
    fn check_finds_issues() {
        let mut d = create(true, b"D:20260101000000Z");
        meta_set(&mut d.pdf, b"Title", "t", MODE_TEXT).unwrap();
        meta_set(&mut d.pdf, b"ModDate", "D:2026", MODE_LITERAL).unwrap();
        let kinds = |d: &Doc, s| check(d, s).unwrap().into_iter().map(|i| i.kind).collect::<Vec<_>>();
        let k = kinds(&d, A1b);
        for want in [Kind::FileId, Kind::OutputIntent, Kind::Metadata, Kind::Version] {
            assert!(k.contains(&want), "{want:?} in {k:?}");
        }
        set(&mut d, A1b, &header(b"RGB ", b"mntr"), &intent()).unwrap();
        assert_eq!(kinds(&d, A1b), vec![]);
        // checked against another standard: its version and XMP do not fit
        let k = kinds(&d, A2b);
        assert!(k.contains(&Kind::Metadata), "{k:?}");
        let k = kinds(&d, X4);
        assert!(k.contains(&Kind::PageBox) && k.contains(&Kind::OutputIntent), "{k:?}");
    }
}
