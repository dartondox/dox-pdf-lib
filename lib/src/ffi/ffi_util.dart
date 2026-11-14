// Shared FFI helpers. The rules (see CONTRIBUTING.md, "Native layout"):
// - every export returns a status; on an error, the message is read with
//   `dox_pdf_last_error` right after, in the same synchronous code;
// - bytes from Rust become a Uint8List with a finalizer (no copy);
// - big load and save run on a Rust thread and end in [Pending].
@DefaultAsset('package:dox_pdf_lib/dox_pdf_lib.dart')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../api/errors.dart';

const int statusOk = 0;
const int statusPending = 1;
const int statusGeneric = 2;
const int statusEncrypted = 3;
const int statusRange = 4;
const int statusEmptyRemove = 5;
const int statusNotFound = 6;
const int statusParse = 7;
const int statusDisposed = 8;

/// The `Bytes` record of Rust (`ffi_util.rs`).
final class NativeBytes extends Struct {
  external Pointer<Uint8> ptr;
  @Size()
  external int len;
  @Size()
  external int cap;
}

@Native<Void Function(Pointer<Int64>)>(
  symbol: 'dox_pdf_last_error',
  isLeaf: true,
)
external void _lastError(Pointer<Int64> out);

@Native<Void Function(Pointer<Void>)>(
  symbol: 'dox_pdf_bytes_free',
  isLeaf: true,
)
external void _bytesFree(Pointer<Void> bytes);

@Native<Void Function(Pointer<Void>)>(symbol: 'dox_pdf_doc_free', isLeaf: true)
external void docFree(Pointer<Void> handle);

/// Finalizer of a document handle.
final Pointer<NativeFinalizerFunction> docFreePointer =
    Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(docFree);

/// A `Bytes` record from Rust as a Uint8List. No copy: Rust frees the
/// memory when the list is garbage collected.
Uint8List takeBytes(int address) {
  Pointer<NativeBytes> bytes = Pointer<NativeBytes>.fromAddress(address);
  return bytes.ref.ptr.asTypedList(
    bytes.ref.len,
    finalizer: Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(
      _bytesFree,
    ).cast(),
    token: bytes.cast(),
  );
}

String takeString(int address) => utf8.decode(takeBytes(address));

/// Throws the typed error of [status], with [message].
Never throwStatus(int status, String message) {
  throw switch (status) {
    statusEncrypted => EncryptedPDFError(),
    statusRange => RangeError(message),
    statusEmptyRemove => RemovePageFromEmptyDocumentError(),
    statusParse => PDFParsingError(message),
    statusDisposed => StateError('The PDFDocument was disposed.'),
    _ => PDFLibError(message),
  };
}

/// Returns [status] when it is OK, pending or not found. Else reads the
/// last error and throws.
int check(int status) {
  if (status == statusOk ||
      status == statusPending ||
      status == statusNotFound) {
    return status;
  }
  Int64List out = Int64List(1);
  _lastError(out.address);
  throwStatus(status, takeString(out[0]));
}

typedef DoneNative = Void Function(Int64, Int32, Int64);

/// Calls that run on a Rust thread. One listener per isolate. It keeps the
/// isolate alive only while a call is pending.
///
// A Rust thread + NativeCallable.listener, not Isolate.run: a thread costs
// tens of microseconds, a new isolate about a millisecond, and the input
// does not have to be copied into another isolate. Rust picks inline or
// thread by size (ffi_util.rs ASYNC_THRESHOLD), so small files pay nothing.
abstract final class Pending {
  static final Map<int, Completer<int>> _waiting = <int, Completer<int>>{};
  static int _next = 0;
  static NativeCallable<DoneNative>? _listener;

  static NativeCallable<DoneNative> get _callable =>
      _listener ??= NativeCallable<DoneNative>.listener(_done)
        ..keepIsolateAlive = false;

  /// The callback pointer for Rust.
  static Pointer<NativeFunction<DoneNative>> get callback =>
      _callable.nativeFunction;

  /// A new call id.
  static int nextId() => ++_next;

  /// Waits for the end of call [id]. Call it right after Rust returned
  /// `PENDING`; the result comes as an event, so it can not be missed.
  static Future<int> wait(int id) {
    Completer<int> completer = Completer<int>();
    _waiting[id] = completer;
    _callable.keepIsolateAlive = true;
    return completer.future;
  }

  static void _done(int id, int status, int value) {
    Completer<int>? completer = _waiting.remove(id);
    if (_waiting.isEmpty) _callable.keepIsolateAlive = false;
    if (completer == null) return;
    if (status == statusOk) {
      completer.complete(value);
    } else {
      try {
        throwStatus(status, takeString(value));
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    }
  }
}
