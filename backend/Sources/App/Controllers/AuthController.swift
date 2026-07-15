import Vapor

struct AccountResponse: Content {
    let configured: Bool
    let signedIn: Bool
    let profile: GoogleOAuth.Profile?
    let subscriptions: [GoogleOAuth.Subscription]
}

struct ConnectResult: Content {
    let signedIn: Bool
    let error: String?
    let subscriptionCount: Int
}

enum AuthController {

    // MARK: Firefox-session sign-in (no Google Cloud setup) — primary path

    static func connect(_ req: Request) async throws -> ConnectResult {
        guard let session = await req.auth.freshSession() else {
            await req.auth.setConnected(false)
            return ConnectResult(signedIn: false, error: "no_session", subscriptionCount: 0)
        }
        async let profileFetch = InnerTube.profile(session: session, client: req.client)
        async let subsFetch = InnerTube.subscriptions(session: session, client: req.client)
        let (profile, subs) = await (profileFetch, subsFetch)
        guard profile != nil || !subs.isEmpty else {
            await req.auth.setConnected(false)
            return ConnectResult(signedIn: false, error: "auth_failed", subscriptionCount: 0)
        }
        await req.auth.setProfile(profile ?? .init(name: "My YouTube", email: "", picture: ""))
        await req.auth.setSubscriptions(subs)
        await req.auth.setConnected(true)
        await req.state.clearFeedCache()
        req.logger.info("connected via Firefox session (\(subs.count) subscriptions)")
        return ConnectResult(signedIn: true, error: nil, subscriptionCount: subs.count)
    }

    static func logout(_ req: Request) async throws -> Response {
        await req.auth.signOut()
        await req.state.clearFeedCache()
        return page("Signed out", "You have been signed out of MiniTube.")
    }

    // MARK: State for the clients

    static func account(_ req: Request) async throws -> AccountResponse {
        // Firefox-session path: no configuration required.
        let signedIn = await req.auth.connected
        return AccountResponse(
            configured: true,
            signedIn: signedIn,
            profile: signedIn ? await req.auth.profile : nil,
            subscriptions: signedIn ? await req.auth.subscriptions : []
        )
    }

    // MARK: HTML helpers

    private static func page(_ title: String, _ message: String) -> Response {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>MiniTube · \(title)</title></head>
        <body style="font-family:system-ui,-apple-system,sans-serif;background:#0f0f0f;color:#f1f1f1;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;text-align:center">
        <div><div style="font-size:40px">▶</div><h2>\(title)</h2><p style="color:#aaa">\(message)</p></div>
        </body></html>
        """
        return Response(status: .ok, headers: ["content-type": "text/html; charset=utf-8"], body: .init(string: html))
    }
}
