import Foundation

/// Immutable inputs for one synchronous backend open. It carries no current
/// playback authority and never reads the VM, preferences, or backend state.
struct PlayerBackendLoadConfiguration {
    let url: URL
    let audioURL: URL?
    let headers: [String: String]
    let startPosition: TimeInterval
    let playbackRate: Float
    let hardwareDecode: Bool
    let networkCaching: TimeInterval
    let maxBuffer: TimeInterval
    let preferNativeVideoToolbox: Bool
    let alternateVideoURLs: [URL]
    let alternateAudioURLs: [URL]
    let readAheadSeconds: TimeInterval?
    let multiConnectionPolicy: MultiConnectionPolicy?
    let liveSource: DemandLiveSource?

    @MainActor
    func load(using backend: any PlayerBackend) {
        backend.load(
            url: url,
            audioURL: audioURL,
            headers: headers,
            startPosition: startPosition,
            playbackRate: playbackRate,
            hardwareDecode: hardwareDecode,
            networkCaching: networkCaching,
            maxBuffer: maxBuffer,
            preferNativeVideoToolbox: preferNativeVideoToolbox,
            alternateVideoURLs: alternateVideoURLs,
            alternateAudioURLs: alternateAudioURLs,
            readAheadSeconds: readAheadSeconds,
            multiConnectionPolicy: multiConnectionPolicy,
            liveSource: liveSource
        )
    }
}

extension PlayerBackendLoadConfiguration {
    static let biliHeaders: [String: String] = [
        "Referer": "https://www.bilibili.com",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    ]

    /// VLC's VOD network-caching delay is paid on every open. Preserve its
    /// two-second startup/runway choice; it is not an HTTP read-ahead bank.
    private static let vodStartupCacheSeconds: TimeInterval = 2

    static func networkCaching(for mode: PlayerMode) -> TimeInterval {
        mode == .vod ? vodStartupCacheSeconds : (mode == .offline ? 1 : 5)
    }

    static func openPosition(
        _ startAt: TimeInterval,
        useAbsoluteVLCSeek: Bool
    ) -> TimeInterval {
        useAbsoluteVLCSeek ? 0 : startAt
    }

    /// Local split DASH must retain its five-second budget: banking tens of
    /// seconds overflows VLC's bounded PCM reserve before the first frame.
    static func maxBufferDuration(
        for mode: PlayerMode,
        configured: TimeInterval,
        nominalBitrate: Int
    ) -> TimeInterval {
        var seconds = mode == .offline ? 5 : configured
        if mode != .live, nominalBitrate > 0 {
            let capBytes = 500.0 * 1024 * 1024
            let secondsAtCap = capBytes / (Double(nominalBitrate) / 8)
            seconds = min(seconds, max(secondsAtCap, 10))
        }
        return seconds
    }

    static func transportURLs(
        video: URL,
        audio: URL?,
        useVLCTransport: Bool
    ) -> (video: URL, audio: URL?) {
        let videoURL = useVLCTransport ? (vlcTransportURL(video) ?? video) : video
        let audioURL = useVLCTransport ? vlcTransportURL(audio) : audio
        return (videoURL, audioURL)
    }

    /// TLS ALPN lets VLC select HTTP/2, whose unknown-length responses defeat
    /// its Range-resume path. Plain HTTP restores HTTP/1.1 for this transport
    /// only; URLSession Smart CDN probes retain HTTPS. Signed queries survive
    /// byte-for-byte through string surgery rather than URLComponents.
    private static func vlcTransportURL(_ url: URL?) -> URL? {
        guard let url,
              url.scheme == "https",
              url.host()?.contains("bilivideo") == true
        else { return url }
        let string = url.absoluteString
        guard string.hasPrefix("https://") else { return url }
        return URL(string: "http://" + string.dropFirst("https://".count)) ?? url
    }
}
