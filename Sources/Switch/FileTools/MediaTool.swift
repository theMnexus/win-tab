import AVFoundation
import Foundation

extension VideoContainer {
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

extension VideoPreset {
    var avPreset: String {
        switch self {
        case .hevc1080: return AVAssetExportPresetHEVC1920x1080
        case .h264_1080: return AVAssetExportPreset1920x1080
        case .h264_720: return AVAssetExportPreset1280x720
        }
    }
}

/// Video and audio through AVAssetExportSession. Encoding runs in the system's media services,
/// so win-tab itself stays small while a long video exports.
enum MediaTool {
    static func run(_ op: FileOperation, source: URL, cancel: CancelToken, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try cancel.check()
        let asset = AVURLAsset(url: source)
        let readable = (try? await asset.load(.isReadable)) ?? false
        guard readable else { throw FileToolError.unreadable(source.lastPathComponent) }
        if try await asset.load(.hasProtectedContent) { throw FileToolError.protectedContent }

        let config: (preset: String, fileType: AVFileType, suffix: String?, ext: String)
        switch op {
        case .compressVideo(let p):
            config = (p.avPreset, .mp4, "compressed", "mp4")
        case .convertVideo(let c):
            config = (AVAssetExportPresetPassthrough, c.fileType, nil, c.rawValue)
        case .toAudio:
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw FileToolError.noAudio }
            config = (AVAssetExportPresetAppleM4A, .m4a, nil, "m4a")
        default:
            throw FileToolError.unsupported("\(op.title) doesn't apply to video")
        }

        var preset = config.preset
        if !(await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: config.fileType)) {
            // Passthrough can't put every codec in every container: re-encode at full quality instead.
            guard case .convertVideo = op,
                  await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetHighestQuality, with: asset, outputFileType: config.fileType) else {
                throw FileToolError.unsupported("This file can't be made into \(config.ext.uppercased())")
            }
            preset = AVAssetExportPresetHighestQuality
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FileToolError.unsupported("This file can't be exported")
        }
        let final = OutputNaming.next(to: source, suffix: config.suffix, ext: config.ext)
        let partial = OutputNaming.partial(for: final)
        defer { try? FileManager.default.removeItem(at: partial) }
        session.outputURL = partial
        session.outputFileType = config.fileType
        session.shouldOptimizeForNetworkUse = true
        cancel.onCancel { session.cancelExport() }
        try await export(session, progress: progress)
        try cancel.check()
        return try OutputNaming.commit(partial, to: final)
    }

    /// Reports progress four times a second while the export runs, and only then.
    private static func export(_ session: AVAssetExportSession, progress: @escaping @Sendable (Double) -> Void) async throws {
        let ticker = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        ticker.schedule(deadline: .now(), repeating: 0.25)
        ticker.setEventHandler { progress(Double(session.progress)) }
        ticker.resume()
        defer { ticker.cancel() }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { done.resume() }
        }
        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            throw FileToolError.cancelled
        default:
            throw session.error.map(FileToolError.from) ?? FileToolError.failed("Export failed")
        }
    }
}
