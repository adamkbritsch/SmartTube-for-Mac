import Vapor
import Leaf

func routes(_ app: Application) throws {
    // ── Web clone (Firefox) ──────────────────────────────────────────────
    app.get { req async throws -> View in
        try await req.view.render("home", HomeContext(settings: await req.state.settings))
    }
    app.get("watch") { req async throws -> View in
        let id = try req.query.get(String.self, at: "v")
        return try await req.view.render("watch", WatchContext(videoID: id, settings: await req.state.settings))
    }
    // Minimal player-only page embedded by the macOS app's WKWebView.
    app.get("embed") { req async throws -> View in
        let id = try req.query.get(String.self, at: "v")
        return try await req.view.render("embed", WatchContext(videoID: id, settings: await req.state.settings))
    }

    // ── JSON API (all clients) ───────────────────────────────────────────
    let api = app.grouped("api")
    api.get("videos", use: VideosController.list)
    api.get("home", use: VideosController.home)
    api.post("feed", "more", use: VideosController.more)
    api.get("feed", "subscriptions", use: VideosController.subscriptionsFeed)
    api.get("feed", "history", use: VideosController.history)
    api.get("playlists", use: VideosController.playlists)
    api.get("playlist", ":id", use: VideosController.playlist)
    api.get("me", use: VideosController.me)
    api.get("notifications", use: VideosController.notifications)
    api.get("shorts", use: VideosController.shorts)
    api.get("search", use: VideosController.search)
    api.post("search", "more", use: VideosController.searchMore)
    api.get("watch", ":id", use: VideosController.watch)
    api.post("comments", "more", use: VideosController.moreComments)
    api.post("subscribe", use: VideosController.subscribe)
    api.post("like", use: VideosController.like)
    api.post("markWatched", use: VideosController.markWatched)
    api.post("hdr", use: VideosController.hdr)
    api.get("channel", ":id", use: VideosController.channel)
    api.get("videos", ":id", use: VideosController.detail)
    api.get("settings", use: SettingsController.get)
    api.patch("settings", use: SettingsController.patch)
    api.get("ublock", use: SettingsController.ublock)
    api.get("adrules", use: SettingsController.adrules)
    api.post("refresh", use: SettingsController.refresh)
    api.get("account", use: AuthController.account)
    api.get("health") { _ async in "ok" }

    // ── Auth (app-owned self-rotating session) ───────────────────────────
    let auth = app.grouped("auth")
    auth.post("cookies", use: AuthController.pushCookies)   // the app pushes its own cookie jar
    auth.post("connect", use: AuthController.connect)       // validate + pull profile/subs
    auth.get("logout", use: AuthController.logout)
    auth.post("logout", use: AuthController.logout)
}

/// Leaf render contexts. `settings` is embedded so the first paint reflects current
/// state; clients then poll `/api/settings` for live updates.
struct HomeContext: Encodable {
    let settings: Settings
}
struct WatchContext: Encodable {
    let videoID: String
    let settings: Settings
}
