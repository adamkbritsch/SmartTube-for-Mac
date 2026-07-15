import Vapor

/// Downloads a real, upstream Adblock-Plus-syntax filter list (EasyList) and
/// extracts the ad-focused cosmetic hiding selectors from it. This is the piece
/// that makes uBlock's behavior "use the updates": the list is re-fetched on a
/// schedule, so whatever the community ships upstream flows into the clients.
enum UBlockListService {
    static let source = "https://easylist.to/easylist/easylist.txt"

    /// Fetch + parse the upstream list. Returns `nil` on any network/parse failure
    /// so callers can keep the previous (or fallback) rules.
    static func fetch(client: Client, logger: Logger) async -> UBlockRules? {
        do {
            var res = try await client.get(URI(string: source))
            guard res.status == .ok, let body = res.body,
                  let text = body.getString(at: body.readerIndex, length: body.readableBytes)
            else {
                logger.warning("uBlock: unexpected response \(res.status) from \(source)")
                return nil
            }
            let parsed = parse(text)
            logger.info("uBlock: parsed \(parsed.totalRules) rules, \(parsed.selectors.count) ad selectors from \(source)")
            return parsed
        } catch {
            logger.warning("uBlock: fetch failed: \(error)")
            return nil
        }
    }

    /// Extract cosmetic element-hide selectors that are generic or YouTube-scoped
    /// and clearly ad-related, so applying them to our clone hides ad units without
    /// collateral damage to normal content.
    static func parse(_ text: String) -> UBlockRules {
        var selectors: [String] = []
        var seen = Set<String>()
        var total = 0
        let cap = 3000

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            total += 1

            // Element-hide cosmetic rule: <domains>##<selector>. Skip exceptions (#@#).
            guard let range = line.range(of: "##"), !line.contains("#@#") else { continue }
            let domains = String(line[line.startIndex..<range.lowerBound])
            let selector = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if selector.isEmpty || selector.hasPrefix("+js") { continue }

            let isGeneric = domains.isEmpty
            let isYouTube = domains.contains("youtube")
            guard isGeneric || isYouTube else { continue }

            // Only ad-related selectors (keeps the applied set focused + safe).
            let lower = selector.lowercased()
            let adRelated = lower.contains("ad") || lower.contains("promoted") || lower.contains("sponsor")
            guard isYouTube || adRelated else { continue }

            // Skip procedural/extended-CSS selectors clients can't apply as plain CSS.
            if selector.contains(":-abp-") || selector.contains(":has-text") || selector.contains(":matches-") { continue }

            if seen.insert(selector).inserted {
                selectors.append(selector)
                if selectors.count >= cap { break }
            }
        }

        // Always include our own ad-unit class + a few known YouTube ad selectors.
        for s in UBlockRules.fallback.selectors where seen.insert(s).inserted {
            selectors.append(s)
        }

        return UBlockRules(selectors: selectors, totalRules: total, source: source, updated: Date())
    }
}
