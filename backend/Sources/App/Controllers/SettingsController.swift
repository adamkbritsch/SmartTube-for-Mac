import Vapor

enum SettingsController {
    /// Read the shared toggle state (web clone + macOS app poll this).
    static func get(_ req: Request) async throws -> Settings {
        await req.state.settings
    }

    /// Update one or more toggles (the companion Firefox extension writes here).
    static func patch(_ req: Request) async throws -> Settings {
        let patch = try req.content.decode(SettingsPatch.self)
        let updated = await req.state.patch(patch)
        req.logger.info("settings updated: \(updated)")
        return updated
    }

    /// The live, auto-updating uBlock cosmetic selectors (clients apply these to
    /// hide ad units when adBlock is on).
    static func ublock(_ req: Request) async throws -> UBlockRules {
        await req.state.ublock
    }

    /// The live, auto-updating YouTube ad-strip keys (uBO json-prune rules). The player
    /// deletes `pruneKeys` from the parsed player response and renames `scrubKeys` to
    /// "no_ads" in raw /player response text.
    static func adrules(_ req: Request) async throws -> AdRules {
        await req.state.adRules
    }

    /// Force an immediate re-pull of the upstream lists (ad rules + EasyList).
    static func refresh(_ req: Request) async throws -> UBlockRules {
        if let ad = await AdRuleService.fetch(client: req.client, logger: req.logger) {
            await req.state.setAdRules(ad)
        }
        if let rules = await UBlockListService.fetch(client: req.client, logger: req.logger) {
            await req.state.setUBlock(rules)
        }
        return await req.state.ublock
    }
}
