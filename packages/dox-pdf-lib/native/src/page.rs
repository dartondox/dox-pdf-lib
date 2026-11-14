//! One page: size, the five boxes and the rotation.

use std::ffi::c_void;

use lopdf::{Document, Object, ObjectId};

use crate::document::{as_f64, deref, inherited, num, page_dict, page_dict_mut, ref_from_i64};
use crate::ffi_util::*;

pub const MEDIA: i32 = 0;
pub const CROP: i32 = 1;
pub const BLEED: i32 = 2;
pub const TRIM: i32 = 3;
pub const ART: i32 = 4;

/// `[x, y, width, height]`, like pdf-lib's `asRectangle`.
pub type Rect = [f64; 4];

fn key(kind: i32) -> Result<&'static str> {
    Ok(match kind {
        MEDIA => "MediaBox",
        CROP => "CropBox",
        BLEED => "BleedBox",
        TRIM => "TrimBox",
        ART => "ArtBox",
        _ => return Err(Error::generic(format!("unknown box {kind}"))),
    })
}

fn rect(pdf: &Document, obj: &Object) -> Result<Rect> {
    let Object::Array(items) = obj else {
        return Err(Error::generic("a page box is not an array"));
    };
    if items.len() != 4 {
        return Err(Error::generic(format!(
            "Attempted to convert PDFArray with {} elements to rectangle, but must have exactly 4 elements.",
            items.len()
        )));
    }
    let mut v = [0.0; 4];
    for (i, item) in items.iter().enumerate() {
        v[i] = deref(pdf, item)
            .and_then(as_f64)
            .ok_or_else(|| Error::generic("a page box value is not a number"))?;
    }
    Ok([v[0], v[1], v[2] - v[0], v[3] - v[1]])
}

/// The box as it is set on the page (or inherited, for media and crop).
fn own_box(pdf: &Document, page: ObjectId, kind: i32) -> Result<Option<Rect>> {
    let dict = page_dict(pdf, page)?;
    let k = key(kind)?.as_bytes();
    let value = if kind == MEDIA || kind == CROP {
        inherited(pdf, dict, k)
    } else {
        dict.get(k).ok().and_then(|v| deref(pdf, v))
    };
    value.map(|v| rect(pdf, v)).transpose()
}

/// pdf-lib's `getXBox`: crop falls back to media; bleed, trim and art fall
/// back to crop.
pub fn get_box(pdf: &Document, page: ObjectId, kind: i32) -> Result<Rect> {
    if let Some(r) = own_box(pdf, page, kind)? {
        return Ok(r);
    }
    match kind {
        // ponytail: pdf-lib throws on a page with no MediaBox at all; readers
        // use US Letter, so we do too
        MEDIA => Ok([0.0, 0.0, 612.0, 792.0]),
        CROP => get_box(pdf, page, MEDIA),
        _ => get_box(pdf, page, CROP),
    }
}

pub fn set_box(pdf: &mut Document, page: ObjectId, kind: i32, r: Rect) -> Result<()> {
    if r.iter().any(|v| !v.is_finite()) {
        return Err(Error::generic("a page box value is not a finite number"));
    }
    let [x, y, w, h] = r;
    let value = Object::Array(vec![num(x), num(y), num(x + w), num(y + h)]);
    page_dict_mut(pdf, page)?.set(key(kind)?, value);
    Ok(())
}

/// `keep` bits of `set_size`: keep the width (setHeight) or the height
/// (setWidth) as it is.
pub const KEEP_WIDTH: i32 = 1;
pub const KEEP_HEIGHT: i32 = 2;

/// pdf-lib's `setSize`. Boxes that were equal to the old media box follow
/// it.
pub fn set_size(pdf: &mut Document, page: ObjectId, width: f64, height: f64, keep: i32) -> Result<()> {
    let media = get_box(pdf, page, MEDIA)?;
    let width = if keep & KEEP_WIDTH != 0 { media[2] } else { width };
    let height = if keep & KEEP_HEIGHT != 0 { media[3] } else { height };
    set_box(pdf, page, MEDIA, [media[0], media[1], width, height])?;
    for kind in [CROP, BLEED, TRIM, ART] {
        let has = own_box(pdf, page, kind)?.is_some();
        if has && get_box(pdf, page, kind)? == media {
            set_box(pdf, page, kind, [media[0], media[1], width, height])?;
        }
    }
    Ok(())
}

pub fn get_rotation(pdf: &Document, page: ObjectId) -> Result<f64> {
    let dict = page_dict(pdf, page)?;
    Ok(inherited(pdf, dict, b"Rotate").and_then(as_f64).unwrap_or(0.0))
}

pub fn set_rotation(pdf: &mut Document, page: ObjectId, degrees: f64) -> Result<()> {
    if degrees % 90.0 != 0.0 {
        return Err(Error::generic(format!(
            "`degreesAngle` must be a multiple of 90, but was actually {degrees}"
        )));
    }
    page_dict_mut(pdf, page)?.set("Rotate", num(degrees));
    Ok(())
}

fn write_f64s(out: *mut f64, values: &[f64]) {
    if out.is_null() {
        return;
    }
    for (i, v) in values.iter().enumerate() {
        // SAFETY: Dart passes room for 4 doubles.
        unsafe { *out.add(i) = *v };
    }
}

/// `out` = x, y, width, height.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_page_get_box(handle: *const c_void, page: i64, kind: i32, out: *mut f64) -> i32 {
    call(|| {
        with_doc(handle, |d| {
            write_f64s(out, &get_box(&d.pdf, ref_from_i64(page), kind)?);
            Ok(OK)
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_page_set_box(
    handle: *const c_void,
    page: i64,
    kind: i32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
) -> i32 {
    call(|| {
        with_doc_mut(handle, |d| {
            set_box(&mut d.pdf, ref_from_i64(page), kind, [x, y, width, height]).map(|_| OK)
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_page_set_size(handle: *const c_void, page: i64, width: f64, height: f64, keep: i32) -> i32 {
    call(|| {
        with_doc_mut(handle, |d| {
            set_size(&mut d.pdf, ref_from_i64(page), width, height, keep).map(|_| OK)
        })
    })
}

/// `out[0]` = the angle in degrees.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_page_get_rotation(handle: *const c_void, page: i64, out: *mut f64) -> i32 {
    call(|| {
        with_doc(handle, |d| {
            write_f64s(out, &[get_rotation(&d.pdf, ref_from_i64(page))?]);
            Ok(OK)
        })
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_page_set_rotation(handle: *const c_void, page: i64, degrees: f64) -> i32 {
    call(|| {
        with_doc_mut(handle, |d| {
            set_rotation(&mut d.pdf, ref_from_i64(page), degrees).map(|_| OK)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::document::{create, insert_page, new_page};

    #[test]
    fn size_and_boxes() {
        let mut d = create(false, b"");
        let p = new_page(&mut d.pdf, 595.28, 841.89);
        insert_page(&mut d.pdf, 0, p).unwrap();
        assert_eq!(get_box(&d.pdf, p, MEDIA).unwrap(), [0.0, 0.0, 595.28, 841.89]);
        assert_eq!(get_box(&d.pdf, p, ART).unwrap(), [0.0, 0.0, 595.28, 841.89]);
        set_box(&mut d.pdf, p, CROP, [0.0, 0.0, 595.28, 841.89]).unwrap();
        set_box(&mut d.pdf, p, TRIM, [10.0, 10.0, 50.0, 50.0]).unwrap();
        set_size(&mut d.pdf, p, 100.0, 0.0, KEEP_HEIGHT).unwrap();
        assert!(set_size(&mut d.pdf, p, f64::NAN, 1.0, 0).is_err());
        assert_eq!(get_box(&d.pdf, p, MEDIA).unwrap(), [0.0, 0.0, 100.0, 841.89]);
        // the crop box was equal to the media box, so it follows
        assert_eq!(get_box(&d.pdf, p, CROP).unwrap(), [0.0, 0.0, 100.0, 841.89]);
        assert_eq!(get_box(&d.pdf, p, TRIM).unwrap(), [10.0, 10.0, 50.0, 50.0]);
    }

    #[test]
    fn rotation() {
        let mut d = create(false, b"");
        let p = new_page(&mut d.pdf, 1.0, 1.0);
        assert_eq!(get_rotation(&d.pdf, p).unwrap(), 0.0);
        set_rotation(&mut d.pdf, p, -90.0).unwrap();
        assert_eq!(get_rotation(&d.pdf, p).unwrap(), -90.0);
        assert!(set_rotation(&mut d.pdf, p, 45.0).is_err());
    }
}
