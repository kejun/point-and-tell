#if os(macOS)
import AVFoundation
import CoreVideo

/// Final-file validation only, after didFinishRecording. Never saves a screenshot
/// or rewrites the movie. Keep one decoded video frame and bounded audio buffers.
enum RecordingMediaInspector {
    struct Report {
        let durationSeconds: Double
        let audio: AudioInspectionReport
    }
    enum ValidationError: LocalizedError {
        case invalidVideo
        var errorDescription: String? { "本地录屏检查失败：视频轨缺失、时长无效或无法解码。文件已保留，未启动自动转写。" }
    }
    static func inspect(movieURL: URL) throws -> Report {
        let asset = AVURLAsset(url: movieURL)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0, let video = asset.tracks(withMediaType: .video).first,
              video.timeRange.duration.seconds.isFinite, video.timeRange.duration.seconds > 0 else {
            throw ValidationError.invalidVideo
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ValidationError.invalidVideo }
        reader.add(output)
        defer { reader.cancelReading() }
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              CMSampleBufferDataIsReady(sample), CMSampleBufferGetImageBuffer(sample) != nil else {
            throw ValidationError.invalidVideo
        }
        reader.cancelReading()
        return Report(durationSeconds: duration, audio: try AudioInspector.inspect(movieURL: movieURL))
    }
}
#endif
