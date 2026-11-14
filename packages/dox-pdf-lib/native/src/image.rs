//! JPEG and PNG images, like pdf-lib's `JpegEmbedder` and `PngEmbedder`.
//!
//! - JPEG: the bytes go into the file as they are (DCTDecode). Size and
//!   color space come from the SOF marker.
//! - PNG: decoded to 8-bit RGBA (palette, gray, 16-bit and interlaced
//!   too), stored as a DeviceRGB image with the alpha in an `SMask` when any
//!   pixel is not opaque. Both are FlateDecode streams.

use std::ffi::c_void;
use std::io::{Cursor, Write};

use lopdf::{Dictionary, Document, Object, ObjectId, Stream};

use crate::document::ref_to_i64;
use crate::draw::deflate;
use crate::ffi_util::*;

const SOF_MARKERS: [u16; 15] = [
    0xffc0, 0xffc1, 0xffc2, 0xffc3, 0xffc5, 0xffc6, 0xffc7, 0xffc8, 0xffc9, 0xffca, 0xffcb, 0xffcc, 0xffcd, 0xffce,
    0xffcf,
];

/// Most bytes a PNG may decode to (as 8-bit RGBA). pdf-lib has no limit; a
/// broken or hostile file must not take all memory.
const PNG_LIMIT: usize = 256 << 20;

fn name(n: &str) -> Object {
    Object::Name(n.as_bytes().to_vec())
}

fn image_dict(width: u32, height: u32, bits: i64, color_space: &str) -> Dictionary {
    let mut d = Dictionary::new();
    d.set("Type", name("XObject"));
    d.set("Subtype", name("Image"));
    d.set("BitsPerComponent", Object::Integer(bits));
    d.set("Width", Object::Integer(width as i64));
    d.set("Height", Object::Integer(height as i64));
    d.set("ColorSpace", name(color_space));
    d
}

/// `(bits per component, width, height, color space)` from the SOF marker,
/// read the way pdf-lib reads it.
fn jpeg_info(data: &[u8]) -> Result<(u8, u16, u16, &'static str)> {
    let invalid = || Error::generic("Invalid JPEG");
    let u16_at = |pos: usize| {
        data.get(pos..pos + 2)
            .map(|b| u16::from_be_bytes([b[0], b[1]]))
            .ok_or_else(invalid)
    };
    if u16_at(0).ok() != Some(0xffd8) {
        return Err(Error::generic("SOI not found in JPEG"));
    }
    let mut pos = 2;
    let mut marker = 0;
    while pos < data.len() {
        marker = u16_at(pos)?;
        pos += 2;
        if SOF_MARKERS.contains(&marker) {
            break;
        }
        pos += u16_at(pos)? as usize;
    }
    if !SOF_MARKERS.contains(&marker) {
        return Err(invalid());
    }
    pos += 2;
    let bits = *data.get(pos).ok_or_else(invalid)?;
    let height = u16_at(pos + 1)?;
    let width = u16_at(pos + 3)?;
    let color_space = match data.get(pos + 5).ok_or_else(invalid)? {
        1 => "DeviceGray",
        3 => "DeviceRGB",
        4 => "DeviceCMYK",
        _ => return Err(Error::generic("Unknown JPEG channel.")),
    };
    Ok((bits, width, height, color_space))
}

pub fn embed_jpg(pdf: &mut Document, data: &[u8]) -> Result<(ObjectId, u32, u32)> {
    let (bits, width, height, color_space) = jpeg_info(data)?;
    let mut dict = image_dict(width as u32, height as u32, bits as i64, color_space);
    dict.set("Filter", name("DCTDecode"));
    if color_space == "DeviceCMYK" {
        // like pdf-lib: most CMYK JPEG files are stored inverted
        let decode = [1, 0, 1, 0, 1, 0, 1, 0].map(Object::Integer).to_vec();
        dict.set("Decode", Object::Array(decode));
    }
    let stream = Stream::new(dict, data.to_vec()).with_compression(false);
    Ok((pdf.add_object(Object::Stream(stream)), width as u32, height as u32))
}

/// A decoded PNG, compressed and ready to add (no document lock needed).
pub struct Png {
    width: u32,
    height: u32,
    rgb: Vec<u8>,
    alpha: Option<Vec<u8>>,
}

fn png_reader(data: &[u8]) -> Result<png::Reader<Cursor<&[u8]>>> {
    let mut decoder = png::Decoder::new_with_limits(Cursor::new(data), png::Limits { bytes: PNG_LIMIT });
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    decoder.read_info().map_err(bad_png)
}

fn bad_png(e: png::DecodingError) -> Error {
    Error::generic(format!("Invalid PNG: {e}"))
}

/// The size of the image as 8-bit RGBA, from the PNG header only. Errors
/// when it is over `PNG_LIMIT`.
pub fn png_decoded_size(data: &[u8]) -> Result<usize> {
    let reader = png_reader(data)?;
    // The png crate panics on a PLTE chunk whose length is not a multiple
    // of 3 (png 0.18.1, transform/palette.rs). The PNG spec says it is an
    // error, so stop here.
    if reader.info().palette.as_ref().is_some_and(|p| p.len() % 3 != 0) {
        return Err(Error::generic("Invalid PNG: the palette length is not a multiple of 3"));
    }
    let (w, h) = reader.info().size();
    let size = (w as usize).saturating_mul(h as usize).saturating_mul(4);
    if size > PNG_LIMIT {
        return Err(Error::generic(format!(
            "the PNG image is too big: {w} x {h} pixels (at most {} MiB decoded)",
            PNG_LIMIT >> 20
        )));
    }
    Ok(size)
}

/// pdf-lib's `PNG.load` (UPNG `toRGBA8` + `splitAlphaChannel`). Rows are
/// converted one by one: the RGB part goes straight into the compressor, so
/// only the alpha (1 byte per pixel) is held in full.
pub fn decode_png(data: &[u8]) -> Result<Png> {
    png_decoded_size(data)?;
    let mut reader = png_reader(data)?;
    if reader.info().animation_control.is_some_and(|a| a.num_frames > 1) {
        return Err(Error::generic("Animated PNGs are not supported"));
    }
    let (width, height) = reader.info().size();
    let (color, _) = reader.output_color_type();
    let pixels = width as usize * height as usize;
    let mut rgb = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    let mut alpha = Vec::with_capacity(pixels);
    let mut line = Vec::with_capacity(width as usize * 3);
    let mut convert = |row: &[u8]| -> Result<()> {
        line.clear();
        match color {
            png::ColorType::Grayscale => row.iter().for_each(|g| {
                line.extend([*g, *g, *g]);
                alpha.push(255);
            }),
            png::ColorType::GrayscaleAlpha => row.as_chunks::<2>().0.iter().for_each(|p| {
                line.extend([p[0], p[0], p[0]]);
                alpha.push(p[1]);
            }),
            png::ColorType::Rgb => row.as_chunks::<3>().0.iter().for_each(|p| {
                line.extend_from_slice(p);
                alpha.push(255);
            }),
            png::ColorType::Rgba => row.as_chunks::<4>().0.iter().for_each(|p| {
                line.extend_from_slice(&p[..3]);
                alpha.push(p[3]);
            }),
            png::ColorType::Indexed => {} // EXPAND makes it RGB(A)
        }
        Ok(rgb.write_all(&line)?)
    };
    if reader.info().interlaced {
        // the passes of an interlaced image only make whole rows at the end
        let mut buf = vec![
            0;
            reader
                .output_buffer_size()
                .ok_or_else(|| Error::generic("Invalid PNG"))?
        ];
        let frame = reader.next_frame(&mut buf).map_err(bad_png)?;
        for row in buf.chunks(frame.line_size).take(height as usize) {
            convert(row)?;
        }
    } else {
        while let Some(row) = reader.next_row().map_err(bad_png)? {
            convert(row.data())?;
        }
    }
    if alpha.len() != pixels {
        return Err(Error::generic("Invalid PNG: unexpected pixel format"));
    }
    let alpha = if alpha.iter().any(|a| *a < 255) {
        Some(deflate(&alpha)?)
    } else {
        None
    };
    Ok(Png {
        width,
        height,
        rgb: rgb.finish()?,
        alpha,
    })
}

fn flate_stream(dict: Dictionary, data: Vec<u8>) -> Object {
    let mut dict = dict;
    dict.set("Filter", name("FlateDecode"));
    Object::Stream(Stream::new(dict, data).with_compression(false))
}

pub fn add_png(pdf: &mut Document, png: Png) -> ObjectId {
    let mut dict = image_dict(png.width, png.height, 8, "DeviceRGB");
    if let Some(alpha) = png.alpha {
        let mut mask = image_dict(png.width, png.height, 8, "DeviceGray");
        mask.set("Decode", Object::Array(vec![Object::Integer(0), Object::Integer(1)]));
        let mask = pdf.add_object(flate_stream(mask, alpha));
        dict.set("SMask", Object::Reference(mask));
    }
    pdf.add_object(flate_stream(dict, png.rgb))
}

/// Width and height of an image object.
#[cfg(test)]
fn image_size(pdf: &Document, id: ObjectId) -> Result<(i64, i64)> {
    let Some(Object::Stream(s)) = pdf.objects.get(&id) else {
        return Err(Error::generic("not an image"));
    };
    let get = |k: &[u8]| s.dict.get(k).and_then(Object::as_i64).map_err(Error::from);
    Ok((get(b"Width")?, get(b"Height")?))
}

fn write3(out: *mut i64, values: [i64; 3]) {
    if out.is_null() {
        return;
    }
    for (i, v) in values.iter().enumerate() {
        // SAFETY: Dart passes room for 3 values.
        unsafe { *out.add(i) = *v };
    }
}

// ---------------------------------------------------------------- exports

/// `out` = image ref, width, height.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_embed_jpg(handle: *const c_void, bytes: *const u8, len: i64, out: *mut i64) -> i32 {
    call(|| {
        let data = slice(bytes, len)?;
        with_doc(handle, |d| {
            let (id, w, h) = embed_jpg(&mut d.pdf, data)?;
            write3(out, [ref_to_i64(id), w as i64, h as i64]);
            Ok(OK)
        })
    })
}

fn add_png_out(handle: *const c_void, png: Png, out: *mut i64) -> Result<i32> {
    let (w, h) = (png.width as i64, png.height as i64);
    let image = with_doc(handle, |d| Ok(add_png(&mut d.pdf, png)))?;
    write3(out, [ref_to_i64(image), w, h]);
    Ok(OK)
}

/// Small image (decoded size under 1 MiB): `out` = image ref, width,
/// height; returns `OK`. Big image:
/// decodes on a Rust thread (it does not touch the document) and returns
/// `PENDING`; `done` gets a decoded-image pointer for `dox_pdf_png_add`.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_embed_png(
    handle: *const c_void,
    bytes: *const u8,
    len: i64,
    out: *mut i64,
    done: DoneCallback,
    id: i64,
) -> i32 {
    call(|| {
        let data = slice(bytes, len)?;
        // by the decoded size: a small file can be a huge image
        if png_decoded_size(data)? < ASYNC_THRESHOLD {
            return add_png_out(handle, decode_png(data)?, out);
        }
        let data = data.to_vec();
        spawn(done, id, move || Ok(Box::into_raw(Box::new(decode_png(&data)?)) as i64))
    })
}

/// Adds a PNG decoded by a `PENDING` `dox_pdf_embed_png` and frees it.
/// `out` = image ref, width, height.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_png_add(handle: *const c_void, png: i64, out: *mut i64) -> i32 {
    call(|| {
        if png == 0 {
            return Err(Error::generic("no decoded image"));
        }
        // SAFETY: the pointer came from `dox_pdf_embed_png` and Dart passes it once.
        let png = unsafe { Box::from_raw(png as *mut Png) };
        add_png_out(handle, *png, out)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_png(width: u32, height: u32, color: png::ColorType, depth: png::BitDepth, data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, width, height);
        e.set_color(color);
        e.set_depth(depth);
        e.write_header().unwrap().write_image_data(data).unwrap();
        out
    }

    fn plain(data: &[u8]) -> Vec<u8> {
        use std::io::Read;
        let mut out = Vec::new();
        flate2::read::ZlibDecoder::new(data).read_to_end(&mut out).unwrap();
        out
    }

    #[test]
    fn png_alpha_goes_into_a_mask() {
        let rgba = [255, 0, 0, 255, 0, 255, 0, 128];
        let png = decode_png(&encode_png(2, 1, png::ColorType::Rgba, png::BitDepth::Eight, &rgba)).unwrap();
        assert_eq!(plain(&png.rgb), [255, 0, 0, 0, 255, 0]);
        assert_eq!(plain(png.alpha.as_ref().unwrap()), [255, 128]);
        let mut pdf = Document::with_version("1.7");
        let id = add_png(&mut pdf, png);
        assert_eq!(image_size(&pdf, id).unwrap(), (2, 1));
        assert!(pdf.get_object(id).unwrap().as_stream().unwrap().dict.has(b"SMask"));
    }

    #[test]
    fn opaque_png_has_no_mask_and_16_bit_gray_is_rgb() {
        let gray16 = [0xff, 0x00, 0x80, 0x00];
        let png = decode_png(&encode_png(
            2,
            1,
            png::ColorType::Grayscale,
            png::BitDepth::Sixteen,
            &gray16,
        ))
        .unwrap();
        assert!(png.alpha.is_none());
        assert_eq!(plain(&png.rgb), [255, 255, 255, 128, 128, 128]);
        // 1-bit gray: 0 and 1 become 0 and 255
        let png = decode_png(&encode_png(
            2,
            1,
            png::ColorType::Grayscale,
            png::BitDepth::One,
            &[0b0100_0000],
        ))
        .unwrap();
        assert_eq!(plain(&png.rgb), [0, 0, 0, 255, 255, 255]);
    }

    #[test]
    fn jpeg_header() {
        // SOI, an APP0 segment of 4 bytes, SOF0: 8 bits, 20 high, 30 wide, 3 channels
        let jpg = [
            0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 8, 0, 20, 0, 30, 3,
        ];
        assert_eq!(jpeg_info(&jpg).unwrap(), (8, 30, 20, "DeviceRGB"));
        assert_eq!(jpeg_info(b"nope").unwrap_err().message, "SOI not found in JPEG");
        assert_eq!(jpeg_info(&jpg[..10]).unwrap_err().message, "Invalid JPEG");
        let mut cmyk = jpg;
        cmyk[17] = 5;
        assert_eq!(jpeg_info(&cmyk).unwrap_err().message, "Unknown JPEG channel.");
    }

    #[test]
    fn png_size_comes_from_the_header() {
        // a small file can be a big image: the decoded size picks the thread
        let gray = vec![0u8; 600 / 8 * 600];
        let file = encode_png(600, 600, png::ColorType::Grayscale, png::BitDepth::One, &gray);
        assert!(file.len() < 10_000);
        assert!(png_decoded_size(&file).unwrap() >= ASYNC_THRESHOLD);
        assert_eq!(decode_png(&file).unwrap().width, 600);
        // over the cap: an error from the header, before any decoding
        let gray = vec![0u8; 9000 / 8 * 8000];
        let file = encode_png(9000, 8000, png::ColorType::Grayscale, png::BitDepth::One, &gray);
        assert!(decode_png(&file).err().unwrap().message.contains("too big"));
    }

    #[test]
    fn palette_with_a_broken_length_is_an_error() {
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, 2, 1);
        e.set_color(png::ColorType::Indexed);
        e.set_palette(vec![255, 0, 0, 0, 255, 0]);
        e.write_header().unwrap().write_image_data(&[0, 1]).unwrap();
        // make the PLTE chunk 4 bytes long (was 6), with a new CRC
        let at = out.windows(4).position(|w| w == b"PLTE").unwrap() - 4;
        let mut chunk = b"PLTE".to_vec();
        chunk.extend_from_slice(&[255, 0, 0, 0]);
        let mut crc = flate2::Crc::new();
        crc.update(&chunk);
        let mut new_chunk = 4u32.to_be_bytes().to_vec();
        new_chunk.extend_from_slice(&chunk);
        new_chunk.extend_from_slice(&crc.sum().to_be_bytes());
        out.splice(at..at + 4 + 4 + 6 + 4, new_chunk);
        let err = decode_png(&out).err().unwrap();
        assert!(err.message.contains("palette"), "{}", err.message);
    }

    #[test]
    fn broken_png_is_an_error() {
        assert!(decode_png(b"\x89PNG\r\n\x1a\nbroken").is_err());
    }
}
