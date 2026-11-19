import Foundation

/// Rules that keep dictated text honest: no invisible or broken characters, no full stop at every pause, and a clean-up
/// that may not rewrite or shorten what was said.
enum TextGuard {
    private static func isBengali(_ v: UInt32) -> Bool { (0x0980...0x09FF).contains(v) }

    /// Removes characters that show as boxes, question marks or nothing: the object/replacement characters, zero-width and
    /// direction marks, private-use and control characters. The joiners Bengali needs (ZWJ, ZWNJ) are kept next to Bengali letters.
    static func sanitize(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, s) in scalars.enumerated() {
            let v = s.value
            if v == 0xFFFC || v == 0xFFFD || v == 0x200B || v == 0xFEFF || v == 0x2060 || v == 0x200E || v == 0x200F { continue }
            if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || (0xE000...0xF8FF).contains(v) { continue }
            if (v >= 0x0900 && v <= 0x0DFF && !(v >= 0x0980 && v <= 0x09FF) && v != 0x0964 && v != 0x0965) { continue } // a stray letter from another Indian script
            if (v < 0x20 && v != 0x0A && v != 0x09) || v == 0x7F { continue }
            if v == 0x200C || v == 0x200D {
                let before = i > 0 && isBengali(scalars[i - 1].value)
                let after = i + 1 < scalars.count && isBengali(scalars[i + 1].value)
                if !(before || after) { continue }
            }
            out.append(s)
        }
        return String(out)
    }

    /// Takes a closing full stop (. or ।) off a piece of speech. People take long pauses, and the recognizer ends a piece at each
    /// pause; the clean-up puts punctuation where a thought really ends.
    static func stripStops(_ text: String) -> String {
        text.replacingOccurrences(of: "[\\s]*[.।…]+[\\s]*$", with: "", options: .regularExpression)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func bengaliShare(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) || isBengali($0.value) }
        guard !letters.isEmpty else { return 0 }
        return Double(letters.filter { isBengali($0.value) }.count) / Double(letters.count)
    }

    /// False when the clean-up changed too much: much shorter or longer, or most words gone. Then the raw words stay.
    static func acceptsPolish(raw: String, polished: String) -> Bool {
        let a = words(raw), b = words(polished)
        guard !a.isEmpty else { return true }
        guard !b.isEmpty else { return false }
        let slack = a.count <= 5 ? 2.0 : 0.0
        if Double(a.count - b.count) > max(slack, Double(a.count) * 0.15) { return false }
        if Double(b.count - a.count) > max(slack, Double(a.count) * 0.25) { return false }
        // Same script: most of the original words must still be there. (Roman Bengali turned into Bengali script is allowed to differ.)
        if abs(bengaliShare(raw) - bengaliShare(polished)) < 0.2 {
            let kept = Set(b)
            let same = a.filter { kept.contains($0) }.count
            if Double(same) / Double(a.count) < 0.55 { return false }
        }
        return true
    }

    /// The share (0 to 1) of the characters that don't belong in English or Bengali text: letters of other scripts (Indian scripts
    /// other than Bengali, Cyrillic, Greek...), accented Latin letters, symbols, replacement boxes. Plain English and Bengali give
    /// about 0; text that came out as byte-shaped noise gives far more.
    static func garbleShare(_ text: String) -> Double {
        var total = 0, odd = 0
        for s in text.unicodeScalars {
            let v = s.value
            if CharacterSet.whitespacesAndNewlines.contains(s) { continue }
            total += 1
            if v < 0x80 || isBengali(v) || v == 0x0964 || v == 0x0965 { continue }
            // Typographic punctuation people really dictate.
            if (0x2010...0x2027).contains(v) || (0x20A0...0x20CF).contains(v) || v == 0x00A3 || v == 0x00A9 || v == 0x00AE || v == 0x00B0 { continue }
            odd += 1
        }
        guard total > 0 else { return 0 }
        // Noise made of ASCII symbols (a Bengali letter cut to one byte looks like that) counts too.
        let symbols = text.unicodeScalars.filter { "@#$%^&*~`|\\<>{}[]_=+".unicodeScalars.contains($0) }.count
        return Double(odd + symbols) / Double(total)
    }

    /// True when a dictation looks like noise rather than words: worth offering to transcribe again from the saved sound.
    static func looksGarbled(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count >= 6 else { return false }
        return garbleShare(trimmed) >= 0.2
    }
}
