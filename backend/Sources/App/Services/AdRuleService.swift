import Vapor

/// Downloads uBlock Origin's live YouTube ad-strip rules (the uAssets repo) and
/// extracts the `json-prune` key paths the player applies. Re-fetched on a schedule
/// so an upstream fix for a YouTube ad change flows to clients with no app update.
///
/// SECURITY: the list is UNTRUSTED text. Extracted keys are character-whitelisted,
/// leaf-only, required to contain "ad", capped in count, and only ever transported to
/// the player as a JSON array of data — NEVER concatenated into JavaScript source.
enum AdRuleService {
    static let sources = [
        "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/quick-fixes.txt",
        "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt",
    ]

    /// Fetch both lists + parse. Returns nil on total failure so the caller keeps the
    /// previous (or cached, or fallback) rules.
    static func fetch(client: Client, logger: Logger) async -> AdRules? {
        var combined = ""
        var gotAny = false
        for src in sources {
            do {
                let res = try await client.get(URI(string: src))
                if res.status == .ok, let body = res.body,
                   let text = body.getString(at: body.readerIndex, length: body.readableBytes) {
                    combined += "\n" + text
                    gotAny = true
                } else {
                    logger.warning("adrules: \(res.status) from \(src)")
                }
            } catch {
                logger.warning("adrules: fetch failed \(src): \(error)")
            }
        }
        guard gotAny else { return nil }
        let parsed = parse(combined)
        logger.info("adrules: prune=\(parsed.pruneKeys) scrub=\(parsed.scrubKeys) from \(parsed.matchedRules) rules")
        return parsed
    }

    private static let scriptletNames: Set<String> = [
        "json-prune", "json-prune-fetch-response", "json-prune-xhr-response",
    ]

    /// Pure + testable. Extracts YouTube json-prune leaf keys from ABP-syntax text.
    static func parse(_ text: String) -> AdRules {
        var prune: [String] = [], scrub: [String] = []
        var seenP = Set<String>(), seenS = Set<String>()
        var matched = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip blanks, comments (drops upstream's commented-out variants), headers, exceptions.
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") || line.contains("#@#") { continue }
            guard let hh = line.range(of: "##") else { continue }
            let domainPart = String(line[line.startIndex..<hh.lowerBound])
            let bodyPart = String(line[hh.upperBound...])
            guard bodyPart.hasPrefix("+js("), let close = bodyPart.lastIndex(of: ")"),
                  let open = bodyPart.firstIndex(of: "("), open < close else { continue }

            // Domain gate: must target youtube.com / www.youtube.com and not exclude it
            // (drops the m./music./tv./kids variant in filters.txt).
            let domains = domainPart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if domains.contains("~youtube.com") || domains.contains("~www.youtube.com") { continue }
            guard domains.contains("youtube.com") || domains.contains("www.youtube.com") else { continue }

            let inner = String(bodyPart[bodyPart.index(after: open)..<close])
            let args = inner.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard args.count >= 2, scriptletNames.contains(args[0]) else { continue }
            let isText = args[0] != "json-prune"   // fetch/xhr response variants → scrub set

            if isText {
                // Only take response-rewrite rules that target the player endpoint.
                guard let pi = args.firstIndex(of: "propsToMatch"), pi + 1 < args.count else { continue }
                let match = args[pi + 1].lowercased()
                guard match.contains("player") || match.contains("get_watch") else { continue }
            }

            var got = false
            for token in args[1].split(separator: " ", omittingEmptySubsequences: true) {
                let t = String(token)
                guard t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "[" || $0 == "]" || $0 == "-" }) else { continue }
                // Leaf = last dot-component that isn't an array marker ([], [-], [0]).
                let comps = t.split(separator: ".").map(String.init)
                guard let leaf = comps.last(where: { !$0.hasPrefix("[") }), isAdKey(leaf) else { continue }
                if isText {
                    if seenS.insert(leaf).inserted, scrub.count < 32 { scrub.append(leaf); got = true }
                } else {
                    if seenP.insert(leaf).inserted, prune.count < 32 { prune.append(leaf); got = true }
                }
            }
            if got { matched += 1 }
        }

        // A set that parsed empty falls back to the built-in triple for that mechanism.
        if prune.isEmpty { prune = AdRules.fallback.pruneKeys }
        if scrub.isEmpty { scrub = AdRules.fallback.scrubKeys }
        return AdRules(pruneKeys: prune, scrubKeys: scrub, matchedRules: matched, sources: sources, updated: Date())
    }

    /// A leaf key is accepted only if it is a short alnum/_/- token that contains "ad".
    /// The client applies keys as RECURSIVE deletes / GLOBAL text renames — a superset of
    /// uBO's exact-path prune — so a vandalized or transiently-broken upstream line must
    /// never be able to delete `streamingData` or rename an arbitrary quoted word. Every
    /// real YouTube ad key so far contains "ad" (adPlacements, playerAds, adSlots,
    /// adBreakHeartbeatParams); this also drops the `legacyImportant` scriptlet option.
    /// Trade-off: a future ad key with no "ad" would need a fallback-triple bump.
    static func isAdKey(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 64,
              s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return false }
        return s.lowercased().contains("ad")
    }
}
