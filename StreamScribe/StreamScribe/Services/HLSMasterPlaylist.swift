import Foundation

/// Picks ONE variant out of an HLS master playlist for a download.
///
/// Why this exists (2026-10-29, Critical Mention clip with audio ~1.2 s late):
/// given a master playlist and no `-map`, ffmpeg opens every variant and
/// chooses streams independently — the video from the highest-resolution
/// variant, the audio from whichever variant's audio comes first (usually
/// the lowest-bitrate one). Each variant is a separately encoded stream with
/// its own timestamp base, so pairing one variant's video with another's
/// audio can put the audio seconds out of sync. That clip's download carried
/// the 720p video with the 62 kb/s audio of a lower variant, offset by
/// 1.3 s; FetchV (one variant, its own audio) was correct.
///
/// Pure parsing, no I/O, so it can be checked in isolation.
nonisolated enum HLSMasterPlaylist {

    struct Variant: Equatable, Sendable {
        let url: URL
        let bandwidth: Int
        let width: Int
        let height: Int
        let audioGroup: String?
    }

    struct Choice: Equatable, Sendable {
        let variant: Variant
        /// Separate audio rendition to pair with the variant, when the
        /// variant's audio is NOT muxed into its own segments.
        let audioURL: URL?
        let variantCount: Int
    }

    /// The variant ffmpeg would have taken the VIDEO from (largest picture,
    /// then highest bandwidth), so the download's picture quality doesn't
    /// change — only its audio now comes from the same variant. Returns nil
    /// for anything that isn't a usable master playlist; callers then keep
    /// their previous behaviour.
    static func choose(in playlist: String, base: URL) -> Choice? {
        var variants: [Variant] = []
        var audioRenditions: [(group: String, uri: URL?, isDefault: Bool)] = []
        var pending: [String: String]?

        for rawLine in playlist.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(line.dropFirst("#EXT-X-MEDIA:".count))
                guard a["TYPE"]?.uppercased() == "AUDIO", let group = a["GROUP-ID"] else { continue }
                let uri = a["URI"].flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
                audioRenditions.append((group, uri, a["DEFAULT"]?.uppercased() == "YES"))
                continue
            }
            if line.hasPrefix("#") { continue }
            // A URI line: belongs to the STREAM-INF just above it, if any.
            guard let attrs = pending else { continue }
            pending = nil
            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            var width = 0, height = 0
            if let res = attrs["RESOLUTION"] {
                let parts = res.lowercased().split(separator: "x")
                if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) { width = w; height = h }
            }
            let bandwidth = Int(attrs["BANDWIDTH"] ?? "") ?? Int(attrs["AVERAGE-BANDWIDTH"] ?? "") ?? 0
            variants.append(Variant(url: url, bandwidth: bandwidth, width: width, height: height,
                                    audioGroup: attrs["AUDIO"]))
        }

        guard let best = variants.max(by: { a, b in
            let areaA = a.width * a.height, areaB = b.width * b.height
            return areaA != areaB ? areaA < areaB : a.bandwidth < b.bandwidth
        }) else { return nil }

        var audioURL: URL?
        if let group = best.audioGroup {
            let inGroup = audioRenditions.filter { $0.group == group }
            // The DEFAULT rendition decides; one with no URI means the audio
            // is muxed into the variant itself. No DEFAULT: take the first.
            audioURL = (inGroup.first(where: { $0.isDefault }) ?? inGroup.first)?.uri
        }
        return Choice(variant: best, audioURL: audioURL, variantCount: variants.count)
    }

    /// `KEY=VALUE,KEY="quoted, with commas"` → dictionary. Keys upper-cased.
    static func attributes(_ list: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var i = list.startIndex
        while i < list.endIndex {
            guard let eq = list[i...].firstIndex(of: "=") else { break }
            let key = list[i..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            var j = list.index(after: eq)
            let value: Substring
            if j < list.endIndex, list[j] == "\"" {
                let start = list.index(after: j)
                let close = list[start...].firstIndex(of: "\"") ?? list.endIndex
                value = list[start..<close]
                j = close < list.endIndex ? list.index(after: close) : close
                if let comma = list[j...].firstIndex(of: ",") { j = list.index(after: comma) } else { j = list.endIndex }
            } else {
                let comma = list[j...].firstIndex(of: ",") ?? list.endIndex
                value = list[j..<comma]
                j = comma < list.endIndex ? list.index(after: comma) : comma
            }
            if !key.isEmpty { out[key] = String(value).trimmingCharacters(in: .whitespaces) }
            i = j
        }
        return out
    }
}
