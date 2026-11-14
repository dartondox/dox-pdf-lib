//! Word breaks inside Thai, Lao, Khmer and Myanmar text.
//!
//! These scripts have no spaces between words. ICU finds the words with a
//! word list (a dictionary) and a small search: the "dictionary break
//! engines" of ICU4C (`dictbe.cpp`). Browsers and Node.js use them for
//! `Intl.Segmenter` with `granularity: 'word'`.
//!
//! This is a port of those engines (ICU 78, `ThaiBreakEngine`,
//! `LaoBreakEngine`, `BurmeseBreakEngine`, `KhmerBreakEngine`), so the breaks
//! are the same as in Node.js. The word lists come from ICU4X
//! (`icu_segmenter` compiled data), which ships the same dictionaries as
//! ICU4C. We do not use the ICU4X segmenter itself: it takes the longest
//! word each time, without the look-ahead of ICU4C, so it breaks some words
//! in another place.
//!
//! Only the four dictionaries are in the library (about 1 MB). The Chinese
//! and Japanese dictionary and the LSTM models are not.
//!
//! The engine code follows ICU4C `dictbe.cpp`: Copyright (C) 2016 and later
//! Unicode, Inc. and others, Unicode License V3. The full license text is in
//! THIRD_PARTY_NOTICES (packages/dox-pdf-lib/THIRD_PARTY_NOTICES).

use std::sync::OnceLock;

use icu_provider::prelude::*;
use icu_segmenter::provider::{Baked, DictionaryBreakData, SegmenterDictionaryExtendedV2};

use crate::ffi_util::{self, Error, OK};

/// A set of code points as sorted, inclusive ranges.
type Set = &'static [(u16, u16)];

fn contains(set: Set, c: u16) -> bool {
    set.iter().any(|&(start, end)| start <= c && c <= end)
}

/// One engine of ICU4C. The sets are `[[:Script:]&[:LineBreak=SA:]]` and
/// its marks (`[:M:]`), from Unicode 18 (the same as pdfme's line break
/// table).
struct Engine {
    /// The ICU4X data key of the dictionary.
    dictionary: &'static str,
    /// ICU4C stores the words as bytes: code point minus this offset.
    offset: u16,
    words: Set,
    marks: Set,
    /// Letters that can start a word (`fBeginWordSet`).
    begin: Set,
    /// Letters of `words` that can not end a word (removed from `fEndWordSet`).
    not_end: Set,
    /// Thai only: a run of 4 letters is one word, and the suffixes
    /// PAIYANNOI and MAIYAMOK join the word before them.
    thai: bool,
}

const THAI: Engine = Engine {
    dictionary: "thaidict",
    offset: 0x0e00,
    words: &[(0x0e01, 0x0e3a), (0x0e40, 0x0e4e)],
    marks: &[(0x0e31, 0x0e31), (0x0e34, 0x0e3a), (0x0e47, 0x0e4e)],
    begin: &[(0x0e01, 0x0e2e), (0x0e40, 0x0e44)],
    not_end: &[(0x0e31, 0x0e31), (0x0e40, 0x0e44)],
    thai: true,
};

const LAO: Engine = Engine {
    dictionary: "laodict",
    offset: 0x0e80,
    words: &[
        (0x0e81, 0x0e82),
        (0x0e84, 0x0e84),
        (0x0e86, 0x0e8a),
        (0x0e8c, 0x0ea3),
        (0x0ea5, 0x0ea5),
        (0x0ea7, 0x0ebd),
        (0x0ec0, 0x0ec4),
        (0x0ec6, 0x0ec6),
        (0x0ec8, 0x0ece),
        (0x0edc, 0x0edf),
    ],
    marks: &[(0x0eb1, 0x0eb1), (0x0eb4, 0x0ebc), (0x0ec8, 0x0ece)],
    begin: &[(0x0e81, 0x0eae), (0x0ec0, 0x0ec4), (0x0edc, 0x0edd)],
    not_end: &[(0x0ec0, 0x0ec4)],
    thai: false,
};

const MYANMAR: Engine = Engine {
    dictionary: "burmesedict",
    offset: 0x1000,
    words: &[
        (0x1000, 0x103f),
        (0x1050, 0x108f),
        (0x109a, 0x109f),
        (0xa9e0, 0xa9ef),
        (0xa9fa, 0xa9fe),
        (0xaa60, 0xaa7f),
    ],
    marks: &[
        (0x102b, 0x103e),
        (0x1056, 0x1059),
        (0x105e, 0x1060),
        (0x1062, 0x1064),
        (0x1067, 0x106d),
        (0x1071, 0x1074),
        (0x1082, 0x108d),
        (0x108f, 0x108f),
        (0x109a, 0x109d),
        (0xa9e5, 0xa9e5),
        (0xaa7b, 0xaa7d),
    ],
    begin: &[(0x1000, 0x102a)],
    not_end: &[],
    thai: false,
};

const KHMER: Engine = Engine {
    dictionary: "khmerdict",
    offset: 0x1780,
    words: &[(0x1780, 0x17d3), (0x17d7, 0x17d7), (0x17dc, 0x17dd)],
    marks: &[(0x17b4, 0x17d3), (0x17dd, 0x17dd)],
    begin: &[(0x1780, 0x17b3)],
    // KHMER SIGN COENG joins the next letter
    not_end: &[(0x17d2, 0x17d2)],
    thai: false,
};

const ENGINES: [&Engine; 4] = [&THAI, &LAO, &MYANMAR, &KHMER];

// ICU4C dictbe.cpp: the same numbers for all four engines.
const LOOKAHEAD: usize = 3;
const ROOT_COMBINE_THRESHOLD: usize = 3;
const PREFIX_COMBINE_THRESHOLD: usize = 3;
const MIN_WORD_SPAN: usize = 4;
const POSSIBLE_WORD_LIST_MAX: usize = 20;
const THAI_PAIYANNOI: u16 = 0x0e2f;
const THAI_MAIYAMOK: u16 = 0x0e46;
const ZWJ: u32 = 0x200d;
const ZWNJ: u32 = 0x200c;

fn dictionary(engine: &Engine) -> Option<&'static DictionaryBreakData<'static>> {
    static DICTIONARIES: [OnceLock<Option<&'static DictionaryBreakData<'static>>>; 4] = [const { OnceLock::new() }; 4];
    let index = ENGINES.iter().position(|e| std::ptr::eq(*e, engine))?;
    *DICTIONARIES[index].get_or_init(|| {
        let key = DataMarkerAttributes::try_from_str(engine.dictionary).ok()?;
        let response: DataResponse<SegmenterDictionaryExtendedV2> = Baked
            .load(DataRequest {
                id: DataIdentifierBorrowed::for_marker_attributes(key),
                ..Default::default()
            })
            .ok()?;
        response.payload.get_static()
    })
}

/// `PossibleWord` of ICU4C: the dictionary words that start at one place.
#[derive(Clone, Copy)]
struct PossibleWord {
    count: usize,
    /// Code points of the longest match with the start of a word.
    prefix: usize,
    offset: Option<usize>,
    mark: usize,
    current: usize,
    lengths: [usize; POSSIBLE_WORD_LIST_MAX],
}

impl PossibleWord {
    const NEW: PossibleWord = PossibleWord {
        count: 0,
        prefix: 0,
        offset: None,
        mark: 0,
        current: 0,
        lengths: [0; POSSIBLE_WORD_LIST_MAX],
    };

    /// Finds the words at `*pos` (once per place), moves `*pos` after the
    /// longest, and returns how many there are.
    fn candidates(&mut self, m: &Matcher, pos: &mut usize) -> usize {
        let start = *pos;
        if self.offset != Some(start) {
            self.offset = Some(start);
            (self.count, self.prefix) = m.matches(start, &mut self.lengths);
        }
        if self.count > 0 {
            *pos = start + self.lengths[self.count - 1];
        }
        // ICU4C: current = mark = count - 1 (unused when count is 0)
        self.current = self.count.saturating_sub(1);
        self.mark = self.current;
        self.count
    }

    fn accept_marked(&self, pos: &mut usize) -> usize {
        *pos = self.offset.unwrap_or(0) + self.lengths[self.mark];
        self.lengths[self.mark]
    }

    fn back_up(&mut self, pos: &mut usize) -> bool {
        if self.current > 0 {
            self.current -= 1;
            *pos = self.offset.unwrap_or(0) + self.lengths[self.current];
            return true;
        }
        false
    }

    fn mark_current(&mut self) {
        self.mark = self.current;
    }
}

/// One run of letters of one engine, and its dictionary.
struct Matcher<'a> {
    engine: &'a Engine,
    dict: &'static DictionaryBreakData<'static>,
    text: &'a [u16],
}

impl Matcher<'_> {
    /// `matches` of ICU4C's `BytesDictionaryMatcher`: the lengths of the
    /// words that start at `start` (at most 20), and the code points read.
    /// All letters of a run are one UTF-16 unit, so lengths in code units
    /// and in code points are the same.
    fn matches(&self, start: usize, lengths: &mut [usize; POSSIBLE_WORD_LIST_MAX]) -> (usize, usize) {
        let DictionaryBreakData::ZeroTrie { alphabet, trie } = self.dict else {
            return (0, 1);
        };
        let max_length = self.text.len() - start;
        let mut cursor = trie.cursor();
        let mut count = 0;
        let mut read = 0;
        for &unit in &self.text[start..] {
            // ICU4C keeps a word as bytes (code point minus the offset). ZWJ
            // and ZWNJ are 0xFF and 0xFE, and a letter outside the 254
            // bytes also reads as 0xFF.
            let c = u32::from(unit);
            let delta = c.wrapping_sub(u32::from(self.engine.offset));
            let c = if c == ZWJ || c == ZWNJ || delta <= 0xfd { c } else { ZWJ };
            cursor.step(alphabet.position32(c).map_or(0xff, |i| i as u8));
            read += 1;
            let has_value = cursor.take_value().is_some();
            let dead = cursor.is_empty();
            if has_value && count < POSSIBLE_WORD_LIST_MAX {
                lengths[count] = read;
                count += 1;
            }
            if dead || read >= max_length {
                break;
            }
        }
        (count, read)
    }
}

impl Engine {
    fn is_end(&self, c: u16) -> bool {
        contains(self.words, c) && !contains(self.not_end, c)
    }

    fn is_mark(&self, c: u16) -> bool {
        c == 0x20 || contains(self.marks, c)
    }

    /// `divideUpDictionaryRange` of ICU4C. `text` is one run of the letters
    /// of this engine; `base` is its place in the whole text. Pushes the
    /// breaks inside the run.
    fn divide(&self, text: &[u16], base: usize, breaks: &mut Vec<usize>) {
        let n = text.len();
        // "Not enough characters for two words". Thai moves 4 code points
        // and needs more, the others need at least 4.
        if (self.thai && n <= MIN_WORD_SPAN) || n < MIN_WORD_SPAN {
            return;
        }
        let Some(dict) = dictionary(self) else {
            return;
        };
        let m = Matcher {
            engine: self,
            dict,
            text,
        };
        let first_break = breaks.len();
        let mut words = [PossibleWord::NEW; LOOKAHEAD];
        let mut found = 0usize;
        let mut pos = 0usize;

        while pos < n {
            let current = pos;
            let mut cu_length = 0;
            let mut cp_length = 0;
            let w = found % LOOKAHEAD;

            let candidates = words[w].candidates(&m, &mut pos);
            if candidates == 1 {
                cu_length = words[w].accept_marked(&mut pos);
                cp_length = cu_length;
                found += 1;
            } else if candidates > 1 {
                // Pick the word that is followed by the most dictionary words.
                'best: {
                    if pos >= n {
                        break 'best;
                    }
                    loop {
                        if words[(found + 1) % LOOKAHEAD].candidates(&m, &mut pos) > 0 {
                            words[w].mark_current();
                            if pos >= n {
                                break 'best;
                            }
                            loop {
                                if words[(found + 2) % LOOKAHEAD].candidates(&m, &mut pos) > 0 {
                                    words[w].mark_current();
                                    break 'best;
                                }
                                if !words[(found + 1) % LOOKAHEAD].back_up(&mut pos) {
                                    break;
                                }
                            }
                        }
                        if !words[w].back_up(&mut pos) {
                            break;
                        }
                    }
                }
                cu_length = words[w].accept_marked(&mut pos);
                cp_length = cu_length;
                found += 1;
            }

            // Not a dictionary word next: join it to the word before, or
            // look for a likely start of the next word.
            if pos < n && cp_length < ROOT_COMBINE_THRESHOLD {
                let w = found % LOOKAHEAD;
                if words[w].candidates(&m, &mut pos) == 0
                    && (cu_length == 0 || words[w].prefix < PREFIX_COMBINE_THRESHOLD)
                {
                    let mut remaining = n - (current + cu_length);
                    let mut chars = 0;
                    loop {
                        let pc = text[pos];
                        pos += 1;
                        chars += 1;
                        remaining -= 1;
                        if remaining == 0 {
                            break;
                        }
                        let uc = text[pos];
                        if self.is_end(pc) && contains(self.begin, uc) {
                            let next = words[(found + 1) % LOOKAHEAD].candidates(&m, &mut pos);
                            pos = current + cu_length + chars;
                            if next > 0 {
                                break;
                            }
                        }
                    }
                    if cu_length == 0 {
                        found += 1;
                    }
                    cu_length += chars;
                } else {
                    pos = current + cu_length;
                }
            }

            // Never stop before a combining mark.
            while pos < n && self.is_mark(text[pos]) {
                pos += 1;
                cu_length += 1;
            }

            // Thai suffixes, when no dictionary word follows.
            if self.thai && pos < n && cu_length > 0 {
                let w = found % LOOKAHEAD;
                let mut uc = text[pos];
                if words[w].candidates(&m, &mut pos) == 0 && (uc == THAI_PAIYANNOI || uc == THAI_MAIYAMOK) {
                    if uc == THAI_PAIYANNOI {
                        let before = text[pos - 1];
                        if before != THAI_PAIYANNOI && before != THAI_MAIYAMOK {
                            pos += 1;
                            cu_length += 1;
                            uc = text.get(pos).copied().unwrap_or(0);
                        }
                    }
                    if uc == THAI_MAIYAMOK && text[pos - 1] != THAI_MAIYAMOK {
                        pos += 1;
                        cu_length += 1;
                    }
                } else {
                    pos = current + cu_length;
                }
            }

            if cu_length > 0 {
                breaks.push(base + current + cu_length);
            }
        }

        // No break at the end of the run.
        if breaks.len() > first_break && breaks.last().is_some_and(|&b| b >= base + n) {
            breaks.pop();
        }
    }
}

/// Line_Break=SA, from Unicode 18 (pdfme's line break table).
const SA: &[(u32, u32)] = &[
    (0x0e01, 0x0e3a),
    (0x0e40, 0x0e4e),
    (0x0e81, 0x0e82),
    (0x0e84, 0x0e84),
    (0x0e86, 0x0e8a),
    (0x0e8c, 0x0ea3),
    (0x0ea5, 0x0ea5),
    (0x0ea7, 0x0ebd),
    (0x0ec0, 0x0ec4),
    (0x0ec6, 0x0ec6),
    (0x0ec8, 0x0ece),
    (0x0edc, 0x0edf),
    (0x1000, 0x103f),
    (0x1050, 0x108f),
    (0x109a, 0x109f),
    (0x1780, 0x17d3),
    (0x17d7, 0x17d7),
    (0x17dc, 0x17dd),
    (0x1950, 0x196d),
    (0x1970, 0x1974),
    (0x1980, 0x19ab),
    (0x19b0, 0x19c9),
    (0x19de, 0x19df),
    (0x1a20, 0x1a5e),
    (0x1a60, 0x1a7c),
    (0x1aa0, 0x1aad),
    (0xa9e0, 0xa9ef),
    (0xa9fa, 0xa9fe),
    (0xaa60, 0xaac2),
    (0xaadb, 0xaadf),
    (0x11700, 0x1171a),
    (0x1171d, 0x1172b),
    (0x1173a, 0x1173b),
    (0x1173f, 0x11746),
];

/// The marks (`[:M:]`) of [SA]. The word rules (UAX #29) keep a mark with
/// the letter before it, but marks at the start of a text are a word alone.
const SA_MARKS: &[(u32, u32)] = &[
    (0x0e31, 0x0e31),
    (0x0e34, 0x0e3a),
    (0x0e47, 0x0e4e),
    (0x0eb1, 0x0eb1),
    (0x0eb4, 0x0ebc),
    (0x0ec8, 0x0ece),
    (0x102b, 0x103e),
    (0x1056, 0x1059),
    (0x105e, 0x1060),
    (0x1062, 0x1064),
    (0x1067, 0x106d),
    (0x1071, 0x1074),
    (0x1082, 0x108d),
    (0x108f, 0x108f),
    (0x109a, 0x109d),
    (0x17b4, 0x17d3),
    (0x17dd, 0x17dd),
    (0x1a55, 0x1a5e),
    (0x1a60, 0x1a7c),
    (0xa9e5, 0xa9e5),
    (0xaa7b, 0xaa7d),
    (0xaab0, 0xaab0),
    (0xaab2, 0xaab4),
    (0xaab7, 0xaab8),
    (0xaabe, 0xaabf),
    (0xaac1, 0xaac1),
    (0x1171d, 0x1172b),
];

fn contains32(set: &[(u32, u32)], c: u32) -> bool {
    set.iter().any(|&(start, end)| start <= c && c <= end)
}

/// The code point at `i` and its length in UTF-16 units. A lone surrogate
/// is its own code point, like JavaScript `codePointAt`.
fn code_point_at(text: &[u16], i: usize) -> (u32, usize) {
    match char::decode_utf16(text[i..].iter().copied()).next() {
        Some(Ok(c)) => (c as u32, c.len_utf16()),
        _ => (u32::from(text[i]), 1),
    }
}

/// The breaks of the engines inside `text[start..end]`, one text of ICU's
/// dictionary step. Each run of letters of one engine is cut alone; there
/// is no break where two runs meet.
fn engine_breaks(text: &[u16], start: usize, end: usize, breaks: &mut Vec<usize>) {
    let mut i = start;
    while i < end {
        let Some(engine) = ENGINES.iter().find(|e| contains(e.words, text[i])) else {
            i += 1;
            continue;
        };
        let run = i;
        while i < end && contains(engine.words, text[i]) {
            i += 1;
        }
        engine.divide(&text[run..i], run, breaks);
    }
}

/// The word breaks inside the Thai, Lao, Khmer and Myanmar text of the
/// UTF-16 `text`, as sorted UTF-16 offsets.
///
/// This is what pdfme gets from `Intl.Segmenter` for each run of SA letters
/// (Line_Break=SA): the segment ends inside the run. Marks at the start of
/// a run are a word alone (UAX #29). The rest is cut into words by the ICU
/// dictionary engines. Other text gives no breaks.
pub fn dictionary_breaks(text: &[u16]) -> Vec<usize> {
    let mut breaks = Vec::new();
    let mut i = 0;
    while i < text.len() {
        let (c, length) = code_point_at(text, i);
        if !contains32(SA, c) {
            i += length;
            continue;
        }
        let start = i;
        let mut marks_end = start;
        while i < text.len() {
            let (c, length) = code_point_at(text, i);
            if !contains32(SA, c) {
                break;
            }
            if marks_end == i && contains32(SA_MARKS, c) {
                marks_end += length;
            }
            i += length;
        }
        if marks_end > start && marks_end < i {
            engine_breaks(text, start, marks_end, &mut breaks);
            breaks.push(marks_end);
            engine_breaks(text, marks_end, i, &mut breaks);
        } else {
            engine_breaks(text, start, i, &mut breaks);
        }
    }
    breaks
}

/// Writes the word breaks of the UTF-16 `text` (`len` code units) into
/// `out` (room for `len` values) and their number into `count`.
#[unsafe(no_mangle)]
pub extern "C" fn dox_pdf_word_breaks(text: *const u16, len: i64, out: *mut i32, count: *mut i64) -> i32 {
    ffi_util::call(|| {
        let len = usize::try_from(len).map_err(|_| Error::generic("bad text length"))?;
        if count.is_null() || (len > 0 && (text.is_null() || out.is_null())) || len > i32::MAX as usize {
            return Err(Error::generic("bad arguments"));
        }
        let found = if len == 0 {
            Vec::new()
        } else {
            // SAFETY: Dart passes `len` code units at `text`.
            dictionary_breaks(unsafe { std::slice::from_raw_parts(text, len) })
        };
        if !found.is_empty() {
            // SAFETY: Dart passes room for `len` values at `out`. The breaks
            // are distinct offsets between 1 and `len - 1`.
            let out = unsafe { std::slice::from_raw_parts_mut(out, len) };
            for (slot, offset) in out.iter_mut().zip(&found) {
                *slot = *offset as i32;
            }
        }
        // SAFETY: Dart passes a pointer to one i64.
        unsafe { *count = found.len().min(len) as i64 };
        Ok(OK)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn breaks(text: &str) -> Vec<usize> {
        dictionary_breaks(&text.encode_utf16().collect::<Vec<u16>>())
    }

    #[test]
    fn dictionaries_load() {
        for engine in ENGINES {
            assert!(dictionary(engine).is_some(), "{}", engine.dictionary);
        }
    }

    #[test]
    fn same_as_node() {
        // Intl.Segmenter of Node.js 24 (ICU 78), without the run ends
        assert_eq!(breaks("ทุกสองสัปดาห์"), [3, 6]);
        assert_eq!(breaks("ดีมาก"), [2]);
        assert_eq!(breaks("เด็กๆ"), [] as [usize; 0]);
        assert_eq!(breaks("ພາສາລາວ"), [4]);
        assert_eq!(breaks("មើលភាសាខ្មែរ"), [3]);
        assert_eq!(breaks("ကျွန်တော်ကျောင်းသွားတယ်"), [9, 16, 20]);
        // runs of two scripts: no break where they meet
        assert_eq!(breaks("ภาษาไทยພາສາລາວ"), [4, 11]);
        // other text: only the runs count
        assert_eq!(breaks("Hello ภาษาไทย!"), [10]);
        // marks at the start of a run are a word alone
        assert_eq!(breaks("\u{0e48}\u{0e48}ภาษาไทย"), [2, 6]);
    }

    #[test]
    fn odd_input() {
        assert!(breaks("").is_empty());
        for text in [
            &[0xd800u16][..],
            &[0xdc00, 0x0e01, 0x0e01, 0x0e01, 0x0e01, 0x0e01],
            &[0x0e48, 0x0e49, 0x0e48, 0x0e49, 0x0e48],
            &[0x0e2f, 0x0e46, 0x0e2f, 0x0e46, 0x0e2f, 0x0e46],
            &[0xaa60, 0xa9e0, 0x1000, 0x1000, 0xaa7f],
            &[0x17d2; 9],
        ] {
            let b = dictionary_breaks(text);
            assert!(b.windows(2).all(|w| w[0] < w[1]), "{b:?}");
            assert!(b.iter().all(|&x| x > 0 && x < text.len()), "{b:?}");
        }
    }

    #[test]
    fn ffi_call() {
        let text: Vec<u16> = "ทุกสองสัปดาห์".encode_utf16().collect();
        let mut out = vec![0i32; text.len()];
        let mut count = 0i64;
        let status = dox_pdf_word_breaks(text.as_ptr(), text.len() as i64, out.as_mut_ptr(), &mut count);
        assert_eq!(status, OK);
        assert_eq!(&out[..count as usize], [3, 6]);
        let status = dox_pdf_word_breaks(std::ptr::null(), 0, std::ptr::null_mut(), &mut count);
        assert_eq!((status, count), (OK, 0));
        let status = dox_pdf_word_breaks(std::ptr::null(), -1, out.as_mut_ptr(), &mut count);
        assert_ne!(status, OK);
    }
}
