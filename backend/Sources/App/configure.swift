import Vapor
import Leaf

public func configure(_ app: Application) async throws {
    // Pin the working directory to the package root (derived from this source
    // file's path) so Public/ and Resources/Views/ resolve no matter where the
    // server is launched from — `swift run` otherwise leaves CWD at the caller.
    let packageRoot = URL(fileURLWithPath: #filePath)   // …/backend/Sources/App/configure.swift
        .deletingLastPathComponent()                    // App
        .deletingLastPathComponent()                    // Sources
        .deletingLastPathComponent()                    // backend
        .path
    app.directory = DirectoryConfiguration(workingDirectory: packageRoot + "/")

    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = Environment.get("MT_PORT").flatMap(Int.init) ?? 8080

    // Outbound client: HTTP/1.1 only. Google's front-end intermittently RST_STREAM-
    // cancels AsyncHTTPClient's HTTP/2 requests once the YouTube cookie header grows
    // large (symptom: StreamClosed errorCode Cancel on every InnerTube call), which
    // broke sign-in. HTTP/1.1 matches curl/Python behavior and is reliable.
    app.http.client.configuration.httpVersion = .http1Only

    // CORS first, so the companion extension + macOS app (other origins) can call the API.
    app.middleware.use(CORSMiddleware(configuration: .init(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PATCH, .OPTIONS],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .userAgent]
    )), at: .beginning)
    app.middleware.use(ErrorMiddleware.default(environment: app.environment))
    app.middleware.use(NoCacheMiddleware())   // player assets must never be served stale
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    app.views.use(.leaf)

    // The pushed cookie jar (POST /auth/cookies) is ~25KB+; raise the 16KB default body limit.
    app.routes.defaultMaxBodySize = "1mb"

    // Shared state (settings + last-good ad rules persisted next to the package).
    let settingsPath = app.directory.workingDirectory + "settings.json"
    let adRulesPath = app.directory.workingDirectory + "adrules.json"
    app.state = AppState(seed: CatalogSeed.videos, settingsPath: settingsPath, adRulesPath: adRulesPath)

    // Auth state — the app's pushed cookie jar (persisted to App Support, survives restart).
    app.auth = AuthState(threadPool: app.threadPool, sessionPath: SessionJar.defaultPath)

    try routes(app)

    app.startBackgroundWork()
}

/// Prevents WKWebView from serving stale cached embed CSS/JS across app relaunches.
struct NoCacheMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store, must-revalidate")
        return response
    }
}

extension Application {
    /// One detached task: pull the live uBlock list, enrich catalog metadata via
    /// oEmbed, warm the SponsorBlock/DeArrow caches, then re-pull the filter list
    /// every 24h so uBlock "uses the updates".
    func startBackgroundWork() {
        let app = self
        Task.detached {
            if let rules = await UBlockListService.fetch(client: app.client, logger: app.logger) {
                await app.state.setUBlock(rules)
            }
            // uBO YouTube ad-strip rules (uAssets) — the live "use the updates" path.
            if let ad = await AdRuleService.fetch(client: app.client, logger: app.logger) {
                await app.state.setAdRules(ad)
            }

            var enriched: [Video] = []
            for v in await app.state.catalog {
                enriched.append(await OEmbedClient.fetch(videoID: v.id, client: app.client, logger: app.logger) ?? v)
            }
            await app.state.setCatalog(enriched)

            for v in enriched {
                let segs = await SponsorBlockClient.fetch(videoID: v.id, client: app.client, logger: app.logger)
                await app.state.storeSegments(segs, v.id)
                let brand = await DeArrowClient.fetch(videoID: v.id, client: app.client, logger: app.logger)
                await app.state.storeBranding(brand, v.id)
            }
            app.logger.info("MiniTube warm-up complete (\(enriched.count) videos)")

            // Scheduled refresh: ad-strip rules every 6h (YouTube ad changes get upstream
            // fixes within hours), EasyList cosmetics every 4th tick (~24h, unchanged).
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
                tick += 1
                if let ad = await AdRuleService.fetch(client: app.client, logger: app.logger) {
                    await app.state.setAdRules(ad)
                    app.logger.info("ad rules refreshed (scheduled)")
                }
                if tick % 4 == 0, let rules = await UBlockListService.fetch(client: app.client, logger: app.logger) {
                    await app.state.setUBlock(rules)
                    app.logger.info("uBlock list refreshed (scheduled)")
                }
            }
        }
    }
}
