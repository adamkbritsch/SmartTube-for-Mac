import Vapor

/// Live client for the real DeArrow branding API (same server as SponsorBlock).
/// Returns the community's best title + a thumbnail URL served by the DeArrow
/// thumbnail service.
enum DeArrowClient {
    /// Resolved, display-ready branding for one video.
    struct Resolved: Sendable {
        let title: String?
        let thumbnail: String?
    }

    static func fetch(videoID: String, client: Client, logger: Logger) async -> Resolved {
        let url = "https://sponsor.ajay.app/api/branding?videoID=\(videoID)"
        do {
            let res = try await client.get(URI(string: url))
            guard res.status == .ok else { return Resolved(title: nil, thumbnail: nil) }
            let branding = try res.content.decode(DeArrowBranding.self)
            return resolve(branding, videoID: videoID)
        } catch {
            logger.warning("DeArrow: failed for \(videoID): \(error)")
            return Resolved(title: nil, thumbnail: nil)
        }
    }

    static func resolve(_ branding: DeArrowBranding, videoID: String) -> Resolved {
        // Best community title: first non-original entry (API returns them ranked).
        let title = branding.titles.first(where: { $0.original != true })
            .map { clean($0.title) }

        // Best community thumbnail with a timestamp → DeArrow thumbnail service URL.
        let thumb = branding.thumbnails.first(where: { $0.original != true && $0.timestamp != nil })
            .flatMap { $0.timestamp }
            .map { "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=\(videoID)&time=\($0)" }

        return Resolved(title: title, thumbnail: thumb)
    }

    /// DeArrow prefixes words with `>` to mark manual capitalization; strip those
    /// markers for display.
    static func clean(_ title: String) -> String {
        title.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces)
    }
}
