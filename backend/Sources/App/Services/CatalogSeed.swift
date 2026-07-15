import Foundation

/// Seed catalog of real, embeddable YouTube video IDs, chosen (by probing the live
/// APIs) for rich SponsorBlock + DeArrow community data so the extension effects are
/// actually visible. Fallback title/channel are used if oEmbed enrichment fails, so
/// the app still works offline after first run.
enum CatalogSeed {
    static let videos: [Video] = [
        v("0e3GPea1Tyg", "$456,000 Squid Game In Real Life!", "MrBeast"),          // SB6 / DA7 — hero
        v("pTn6Ewhb27k", "Why No One Has Measured The Speed Of Light", "Veritasium"), // SB2 / DA2
        v("AaZ_RSt0KP8", "The Universe is Hostile to Computers", "Veritasium"),      // SB1 / DA3
        v("IV3dnLzthDA", "The Man Who Accidentally Killed The Most People", "Veritasium"), // SB2 / DA3
        v("HeQX2HjkcNo", "Math's Fundamental Flaw", "Veritasium"),                   // SB1 / DA4
        v("bHIhgxav9LY", "The Big Misconception About Electricity", "Veritasium"),   // SB2
        v("LEENEFaVUzU", "The Last Human – A Glimpse Into The Far Future", "Kurzgesagt – In a Nutshell"), // DA1
        v("4b33NTAuF5E", "Can You Upload Your Mind & Live Forever?", "Kurzgesagt – In a Nutshell"),       // DA1
        v("qEfPBt9dU60", "What if We Nuke the Moon?", "Kurzgesagt – In a Nutshell"), // DA1
        v("Unzc731iCUY", "How to Speak", "MIT OpenCourseWare"),                      // SB1
        v("dQw4w9WgXcQ", "Never Gonna Give You Up", "Rick Astley"),                  // DA3
        v("aqz-KE-bpKQ", "Big Buck Bunny 60fps 4K", "Blender Foundation"),           // DA1 — open source
    ]

    private static func v(_ id: String, _ title: String, _ channel: String) -> Video {
        Video(id: id, title: title, channel: channel, thumbnail: Video.defaultThumbnail(id))
    }
}
