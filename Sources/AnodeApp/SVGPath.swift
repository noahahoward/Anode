import AppKit

/// A small reader for SVG path data, enough for the Hardware View's Apple logo and its pipe polylines.
///
/// Supported: `M L C Z` and their lowercase (relative) forms, with the usual shorthands: several coordinate sets after one
/// letter repeat the command (after `M` they are line-tos), and numbers may be packed (`3.96.948`, `1.5-2`). Anything else, a
/// missing number, or a path that draws nothing gives nil; the caller then draws no logo rather than a broken one.
enum SVGPath {

    static func bezier(_ d: String) -> NSBezierPath? {
        guard let tokens = tokenize(d), !tokens.isEmpty else { return nil }

        let path = NSBezierPath()
        var command: Character?
        var current = NSPoint.zero
        var start = NSPoint.zero
        var hasStart = false
        var drew = false
        var i = 0

        func next(_ count: Int) -> [Double]? {
            guard i + count <= tokens.count else { return nil }
            var out: [Double] = []
            for k in 0..<count {
                guard case .number(let v) = tokens[i + k] else { return nil }
                out.append(v)
            }
            i += count
            return out
        }

        while i < tokens.count {
            if case .command(let c) = tokens[i] {
                command = c
                i += 1
                if c == "Z" || c == "z" {
                    guard hasStart else { return nil }
                    path.close()
                    current = start
                    command = nil
                }
                continue
            }
            // A number with no command to use it (after Z, or before any M).
            guard let c = command else { return nil }
            let relative = c.isLowercase
            let dx = relative ? current.x : 0
            let dy = relative ? current.y : 0
            switch c {
            case "M", "m":
                guard let v = next(2) else { return nil }
                current = NSPoint(x: v[0] + dx, y: v[1] + dy)
                start = current
                hasStart = true
                path.move(to: current)
                // More pairs after a move are line-tos.
                command = relative ? "l" : "L"
            case "L", "l":
                guard hasStart, let v = next(2) else { return nil }
                current = NSPoint(x: v[0] + dx, y: v[1] + dy)
                path.line(to: current)
                drew = true
            case "C", "c":
                guard hasStart, let v = next(6) else { return nil }
                let c1 = NSPoint(x: v[0] + dx, y: v[1] + dy)
                let c2 = NSPoint(x: v[2] + dx, y: v[3] + dy)
                let end = NSPoint(x: v[4] + dx, y: v[5] + dy)
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
                current = end
                drew = true
            default:
                return nil
            }
        }
        return drew ? path : nil
    }

    // MARK: - Reading

    private enum Token {
        case command(Character)
        case number(Double)
    }

    /// Letters and numbers, or nil on anything that is neither (or a letter this reader does not do).
    private static func tokenize(_ d: String) -> [Token]? {
        let chars = Array(d)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == " " || ch == "," || ch == "\n" || ch == "\t" || ch == "\r" {
                i += 1
            } else if "MmLlCcZz".contains(ch) {
                tokens.append(.command(ch))
                i += 1
            } else if ch == "-" || ch == "+" || ch == "." || ch.isASCII && ch.isNumber {
                let begin = i
                if chars[i] == "-" || chars[i] == "+" { i += 1 }
                var digits = 0
                while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
                if i < chars.count, chars[i] == "." {
                    i += 1
                    while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
                }
                guard digits > 0 else { return nil }
                // An exponent, only when digits really follow it.
                if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
                    if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                        i = j
                    }
                }
                guard let v = Double(String(chars[begin..<i])), v.isFinite else { return nil }
                tokens.append(.number(v))
            } else {
                return nil
            }
        }
        return tokens
    }
}
