import Vapor

/// Live client for the real SponsorBlock API. Fetched per request (with a short
/// TTL cache held in AppState) so segments always reflect current community data —
/// no frozen snapshot.
enum SponsorBlockClient {
    static let categories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "music_offtopic"]

    static func fetch(videoID: String, client: Client, logger: Logger) async -> [SponsorSegment] {
        let cats = categories.map { "\"\($0)\"" }.joined(separator: ",")
        guard let catsEncoded = "[\(cats)]".addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else {
            return []
        }
        let url = "https://sponsor.ajay.app/api/skipSegments?videoID=\(videoID)&categories=\(catsEncoded)"
        do {
            let res = try await client.get(URI(string: url))
            // 404 means "no segments for this video" — a normal, empty result.
            guard res.status == .ok else { return [] }
            let segments = try res.content.decode([SponsorSegment].self)
            return segments.filter { $0.segment.count >= 2 }
        } catch {
            logger.warning("SponsorBlock: failed for \(videoID): \(error)")
            return []
        }
    }
}
