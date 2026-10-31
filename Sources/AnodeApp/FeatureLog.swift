import AppKit

/// A small append-only log for a feature that has to be diagnosed after the fact, because what goes
/// wrong with it does not go wrong on demand. One file per feature in Anode's support folder,
/// readable by this user alone, never following a symlink planted at its path, and kept small: past
/// `maxBytes` the old half is dropped. Text from outside (an app name) is cleaned before it is written,
/// so it cannot forge a line.
enum FeatureLog {

    static let maxBytes = 64 * 1024

    static func append(_ name: String, _ text: String, now: Date = Date()) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Anode") else { return }
        let url = dir.appendingPathComponent(name)
        let line = "\(ISO8601DateFormatter().string(from: now)) \(clean(text, limit: 240))\n"
        trim(url)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// No control characters (a newline would forge a line) and at most `limit` characters.
    static func clean(_ s: String, limit: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(limit)))
    }

    /// Keep the file under `maxBytes` by dropping its older half, from a line boundary.
    static func trim(_ url: URL, maxBytes: Int = FeatureLog.maxBytes) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(maxBytes / 2)
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: newline)) }
        let fd = open(url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = Array(tail).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
