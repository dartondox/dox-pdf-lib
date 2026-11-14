//! Shared FFI helpers. Every export uses them, so the rules below hold for
//! the whole library:
//!
//! - An export returns an `i32` status (`OK`, `PENDING` or an error code).
//! - On an error, the message is in a thread-local slot. Dart reads it with
//!   `dox_pdf_last_error`, in the same synchronous Dart code, so on the same
//!   thread.
//! - No panic crosses FFI: `call` wraps every export in `catch_unwind`.
//! - The document lives in Rust. Dart holds an `Arc<Doc>` pointer (the
//!   handle) and frees it with `dox_pdf_doc_free`.
//! - Bytes for Dart (a saved PDF, a string) are a `Bytes` record. Dart wraps
//!   them as a `Uint8List` with `dox_pdf_bytes_free` as its finalizer, so
//!   there is no copy and no extra call.

use std::cell::RefCell;
use std::ffi::c_void;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, MutexGuard};

use lopdf::Document;

pub const OK: i32 = 0;
/// The work runs on a Rust thread. The callback gets the result.
pub const PENDING: i32 = 1;
pub const ERR_GENERIC: i32 = 2;
pub const ERR_ENCRYPTED: i32 = 3;
pub const ERR_RANGE: i32 = 4;
pub const ERR_EMPTY_REMOVE: i32 = 5;
pub const ERR_NOT_FOUND: i32 = 6;
pub const ERR_PARSE: i32 = 7;
pub const ERR_DISPOSED: i32 = 8;
/// Embed: the page has no `/Contents` (pdf-lib's MissingPageContentsEmbeddingError).
pub const ERR_MISSING_CONTENTS: i32 = 20;
/// A pdf-lib form error. The message is `<error class>\0<text>`.
pub const ERR_FORM: i32 = 9;

/// Input or output at least this big runs on a Rust thread, so a large
/// load or save does not block the Dart event loop. Smaller work runs
/// inline: a thread and a callback cost more than the work itself.
pub const ASYNC_THRESHOLD: usize = 1 << 20;

#[derive(Debug)]
pub struct Error {
    pub status: i32,
    pub message: String,
}

impl Error {
    pub fn new(status: i32, message: impl Into<String>) -> Self {
        Error {
            status,
            message: message.into(),
        }
    }

    pub fn generic(message: impl Into<String>) -> Self {
        Error::new(ERR_GENERIC, message)
    }
}

impl From<lopdf::Error> for Error {
    fn from(e: lopdf::Error) -> Self {
        Error::generic(e.to_string())
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::generic(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// The document state behind a handle. Later feature areas add fields here
/// (eg. fonts to embed at save). Keep it `Clone`: a fast in-memory copy of
/// a loaded document (load a template once, copy it per output) is one
/// clone under the lock, with no parse.
#[derive(Clone, Default)]
pub struct Doc {
    pub pdf: Document,
    pub draw: crate::draw::DrawState,
    pub embed: crate::embed::EmbedState,
    /// Goes up on every call that changes the document (`with_doc_mut`).
    /// The embed cache of another document checks it.
    pub generation: u64,
    pub form: crate::form::FormState,
}

pub type Shared = Mutex<Doc>;

thread_local! {
    static LAST_ERROR: RefCell<String> = const { RefCell::new(String::new()) };
}

fn set_last_error(message: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = message);
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    let text = payload
        .downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "unknown".to_string());
    format!("internal error: {text}")
}

/// Runs the body of an export. Returns `OK`, or the error status with the
/// message in the last-error slot. A panic becomes `ERR_GENERIC`.
pub fn call(f: impl FnOnce() -> Result<i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(status)) => status,
        Ok(Err(e)) => {
            set_last_error(e.message);
            e.status
        }
        Err(payload) => {
            set_last_error(panic_message(payload));
            ERR_GENERIC
        }
    }
}

/// Byte buffer handed to Dart. Freed by `dox_pdf_bytes_free`.
#[repr(C)]
pub struct Bytes {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

/// Moves `data` into a `Bytes` record and returns its address.
pub fn bytes_into_raw(data: Vec<u8>) -> i64 {
    let mut data = std::mem::ManuallyDrop::new(data);
    let bytes = Box::new(Bytes {
        ptr: data.as_mut_ptr(),
        len: data.len(),
        cap: data.capacity(),
    });
    Box::into_raw(bytes) as i64
}

/// Writes the last error into `out` as a `Bytes` address (UTF-8).
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_last_error(out: *mut i64) {
    let message = LAST_ERROR.with(|e| std::mem::take(&mut *e.borrow_mut()));
    if !out.is_null() {
        // SAFETY: Dart passes a valid pointer to one i64.
        unsafe { *out = bytes_into_raw(message.into_bytes()) };
    }
}

/// Finalizer of the `Uint8List` that Dart makes from a `Bytes` record.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_bytes_free(bytes: *mut c_void) {
    if bytes.is_null() {
        return;
    }
    let _ = catch_unwind(|| {
        // SAFETY: the pointer came from `bytes_into_raw` and is freed once.
        let b = unsafe { Box::from_raw(bytes as *mut Bytes) };
        drop(unsafe { Vec::from_raw_parts(b.ptr, b.len, b.cap) });
    });
}

/// Frees a document handle. Dart calls it from `dispose()` or from its
/// `NativeFinalizer`. A save that still runs on a Rust thread writes its own
/// copy, so it does not need the handle.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_doc_free(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    let _ = catch_unwind(|| {
        // SAFETY: the pointer came from `handle_into_raw` and is freed once.
        drop(unsafe { Arc::from_raw(handle as *const Shared) });
    });
}

pub fn handle_into_raw(doc: Doc) -> i64 {
    Arc::into_raw(Arc::new(Mutex::new(doc))) as i64
}

/// A new owned `Arc` from a handle, for work on another thread or to hold
/// two documents at once.
pub fn handle_arc(handle: *const c_void) -> Result<Arc<Shared>> {
    if handle.is_null() {
        return Err(Error::new(ERR_DISPOSED, "the document was disposed"));
    }
    let ptr = handle as *const Shared;
    // SAFETY: Dart keeps the handle alive while it calls us.
    unsafe {
        Arc::increment_strong_count(ptr);
        Ok(Arc::from_raw(ptr))
    }
}

pub fn handle_ref<'a>(handle: *const c_void) -> Result<&'a Shared> {
    if handle.is_null() {
        return Err(Error::new(ERR_DISPOSED, "the document was disposed"));
    }
    // SAFETY: Dart keeps the handle alive while it calls us.
    Ok(unsafe { &*(handle as *const Shared) })
}

pub fn lock(shared: &Shared) -> Result<MutexGuard<'_, Doc>> {
    shared
        .lock()
        .map_err(|_| Error::generic("the document is broken after an internal error; load it again"))
}

/// Locks the document of a handle and runs `f` on it.
pub fn with_doc<T>(handle: *const c_void, f: impl FnOnce(&mut Doc) -> Result<T>) -> Result<T> {
    let shared = handle_ref(handle)?;
    let mut doc = lock(shared)?;
    f(&mut doc)
}

/// `with_doc` for a call that changes the document: it also moves
/// `generation` up.
pub fn with_doc_mut<T>(handle: *const c_void, f: impl FnOnce(&mut Doc) -> Result<T>) -> Result<T> {
    with_doc(handle, |d| {
        d.generation = d.generation.wrapping_add(1);
        f(d)
    })
}

/// Called once the work of a `PENDING` call ends: `(id, status, value)`.
/// On `OK`, `value` is the result. On an error, it is a `Bytes` address with
/// the message.
pub type DoneCallback = extern "C" fn(i64, i32, i64);

/// Runs `job` on a new thread and reports to `done`. Returns `PENDING`.
pub fn spawn(done: DoneCallback, id: i64, job: impl FnOnce() -> Result<i64> + Send + 'static) -> Result<i32> {
    std::thread::Builder::new()
        .name("dox_pdf_lib".into())
        .spawn(move || {
            let (status, value) = match catch_unwind(AssertUnwindSafe(job)) {
                Ok(Ok(value)) => (OK, value),
                Ok(Err(e)) => (e.status, bytes_into_raw(e.message.into_bytes())),
                Err(payload) => (ERR_GENERIC, bytes_into_raw(panic_message(payload).into_bytes())),
            };
            done(id, status, value);
        })
        .map_err(|e| Error::generic(format!("can not start a thread: {e}")))?;
    Ok(PENDING)
}

/// Copies `len` bytes at `ptr` into a slice view.
pub fn slice<'a>(ptr: *const u8, len: i64) -> Result<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() || len < 0 {
        return Err(Error::generic("bad input buffer"));
    }
    // SAFETY: Dart passes a buffer of `len` bytes that lives for the call.
    Ok(unsafe { std::slice::from_raw_parts(ptr, len as usize) })
}

pub fn write_out(out: *mut i64, value: i64) {
    if !out.is_null() {
        // SAFETY: Dart passes a pointer to its out buffer.
        unsafe { *out = value };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn call_catches_a_panic() {
        let status = call(|| panic!("boom"));
        assert_eq!(status, ERR_GENERIC);
        let mut out = 0i64;
        dox_pdf_last_error(&mut out);
        let b = unsafe { &*(out as *const Bytes) };
        let text = unsafe { std::slice::from_raw_parts(b.ptr, b.len) };
        assert_eq!(text, b"internal error: boom");
        dox_pdf_bytes_free(out as *mut c_void);
    }

    #[test]
    fn call_keeps_the_error_status() {
        assert_eq!(call(|| Err(Error::new(ERR_RANGE, "x"))), ERR_RANGE);
    }
}
