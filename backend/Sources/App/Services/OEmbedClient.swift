import Vapor

/// Fetches basic video metadata (title, channel, thumbnail) from YouTube's public
/// oEmbed endpoint — no API key required. Only used to enrich the seed catalog.
enum OEmbedClient {
    struct Response: Content {
        let title: String?
        let author_name: String?
        let thumbnail_url: String?
    }

    static func fetch(videoID: String, client: Client, logger: Logger) async -> Video? {
        let watch = "https://www.youtube.com/watch?v=\(videoID)"
        guard let encoded = watch.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) else {
            return nil
        }
        let url = "https://www.youtube.com/oembed?url=\(encoded)&format=json"
        do {
            let res = try await client.get(URI(string: url))
            guard res.status == .ok else {
                logger.warning("oEmbed: \(res.status) for \(videoID)")
                return nil
            }
            let data = try res.content.decode(Response.self)
            return Video(
                id: videoID,
                title: data.title ?? videoID,
                channel: data.author_name ?? "Unknown channel",
                thumbnail: data.thumbnail_url ?? Video.defaultThumbnail(videoID)
            )
        } catch {
            logger.warning("oEmbed: failed for \(videoID): \(error)")
            return nil
        }
    }
}

extension CharacterSet {
    /// Percent-encoding set safe for a URL query *value* (encodes `:` `/` `?` `&` `=`).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
