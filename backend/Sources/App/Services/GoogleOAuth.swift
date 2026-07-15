import Vapor

/// Namespace kept so GoogleOAuth.Profile / GoogleOAuth.Subscription references compile unchanged.
enum GoogleOAuth {
    struct Profile: Content, Sendable { let name: String; let email: String; let picture: String }
    struct Subscription: Content, Sendable { let title: String; let thumbnail: String; let channelId: String }
}
