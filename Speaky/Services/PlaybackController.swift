import Foundation
import os

private let logger = Logger.speaky(category: "PlaybackController")

/// Controls media playback (pause/resume) during recording sessions.
/// Uses the private MediaRemote framework for precise pause/play commands.
/// Only resumes if something was actually playing when we paused.
final class PlaybackController: @unchecked Sendable {
    private typealias MRSendCommandFunc = @convention(c) (UInt32, AnyObject?) -> Bool
    private typealias MRGetNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void

    private let sendCommand: MRSendCommandFunc?
    private let getNowPlayingInfo: MRGetNowPlayingInfoFunc?
    private var didPause = false

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1

    init() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        ) else {
            logger.warning("Failed to load MediaRemote framework")
            sendCommand = nil
            getNowPlayingInfo = nil
            return
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            sendCommand = unsafeBitCast(ptr, to: MRSendCommandFunc.self)
        } else {
            sendCommand = nil
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            getNowPlayingInfo = unsafeBitCast(ptr, to: MRGetNowPlayingInfoFunc.self)
        } else {
            getNowPlayingInfo = nil
        }
    }

    /// Pause currently playing media. Only marks didPause if something is actually playing.
    func pause() {
        guard let sendCommand else { return }

        // Check if media is currently playing before sending pause
        if let getNowPlayingInfo {
            let semaphore = DispatchSemaphore(value: 0)
            var isPlaying = false

            getNowPlayingInfo(DispatchQueue.global(qos: .userInitiated)) { info in
                // kMRMediaRemoteNowPlayingInfoPlaybackRate key = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
                if let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double, rate > 0 {
                    isPlaying = true
                }
                semaphore.signal()
            }

            // Wait briefly — if it times out, skip pause to be safe
            if semaphore.wait(timeout: .now() + 0.1) == .timedOut {
                logger.debug("NowPlaying info timed out — skipping pause")
                return
            }

            guard isPlaying else {
                logger.debug("Nothing playing — skipping pause")
                return
            }
        }

        _ = sendCommand(Self.kMRPause, nil)
        didPause = true
        logger.debug("Media paused")
    }

    /// Resume media only if we actually paused something.
    func resume() {
        guard didPause, let sendCommand else { return }
        _ = sendCommand(Self.kMRPlay, nil)
        didPause = false
        logger.debug("Media resumed")
    }
}
