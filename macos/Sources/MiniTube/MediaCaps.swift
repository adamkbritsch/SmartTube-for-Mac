import Foundation
import VideoToolbox

/// Hardware media capability, probed once at launch and cached (mirrors `MTDebug`).
///
/// Why it matters: on current WebKit (macOS Sequoia/Tahoe, Safari 18+) VP9 decode was
/// removed, so YouTube's 1440p/2160p SDR *and* all HDR streams are VP9 or AV1 only. The
/// only codec left that a non-AV1 Mac can decode is H.264, which YouTube caps at 1080p,
/// and WebKit ships no AV1 software decoder — so a Mac without an AV1 *hardware* decoder
/// (i.e. anything below Apple Silicon M3) can't do HDR/4K in a WKWebView at all. The app
/// therefore requires an AV1 hardware decoder and gates itself to M3+.
enum MediaCaps {
    /// Test override: force the "unsupported hardware" gate on a capable Mac so the M3-only
    /// developer can exercise the gate path. Reuses the existing `/tmp/mt-*` flag-file idiom.
    static let forceUnsupported: Bool =
        ProcessInfo.processInfo.environment["MT_FORCE_SDR"] != nil
        || FileManager.default.fileExists(atPath: "/tmp/mt-force-sdr")

    /// True only where an AV1 hardware decoder exists (Apple Silicon M3+). Evaluated once;
    /// `VTIsHardwareDecodeSupported` is the clean, model-independent capability probe.
    static let supported: Bool =
        !forceUnsupported && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// Human-readable reason shown at the gate when `supported` is false.
    static let unsupportedMessage =
        "MiniTube requires a Mac with an AV1 hardware decoder (Apple Silicon M3 or newer).\n\n"
        + "Apple removed VP9 decoding from WebKit, so YouTube HDR and 4K now require AV1 — "
        + "which only M3-and-newer chips can decode. On older Macs playback would be limited "
        + "to 1080p SDR, so MiniTube doesn't run there."
}
