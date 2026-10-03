import Foundation

/// Preserve the stage and nested NSError codes that NSAlert(error:) can hide.
/// No raw userInfo, device IDs, audio, or credentials are included in the report.
public struct CaptureFailure: LocalizedError {
    public enum Stage: String {
        case permissions, destination, microphoneInput, configuration
        case sessionStart, movieStart, recording, pausing, resuming, finalization

        public var title: String {
            switch self {
            case .permissions: return "检查录制权限"
            case .destination: return "准备录制文件"
            case .microphoneInput: return "打开麦克风"
            case .configuration: return "配置屏幕与音频"
            case .sessionStart: return "启动采集会话"
            case .movieStart: return "启动录屏文件写入"
            case .recording: return "录制屏幕与麦克风"
            case .pausing: return "暂停录制"
            case .resuming: return "恢复录制"
            case .finalization: return "结束并保存录屏"
            }
        }

        public var suggestion: String {
            switch self {
            case .permissions:
                return "请检查系统隐私设置中的屏幕录制和麦克风权限；如系统要求，退出并重新打开应用。"
            case .destination:
                return "请在可写的本地文件夹新建项目，并检查剩余磁盘空间。"
            case .microphoneInput:
                return "请检查所选麦克风是否连接，并在系统声音设置中确认输入设备可用。"
            case .configuration, .sessionStart, .movieStart:
                return "请确认屏幕和麦克风仍可用，退出并重新打开应用后重试。若仍失败，请复制下方诊断信息。"
            case .recording, .pausing, .resuming, .finalization:
                return "请检查设备连接和磁盘空间。已经写入的录屏和截图仍保留在原项目中。"
            }
        }
    }

    public let stage: Stage
    public let details: [String]
    public var errorDescription: String? { stage.title + "失败" }
    public var failureReason: String? { details.joined(separator: "\n") }
    public var recoverySuggestion: String? { stage.suggestion }
    public var diagnosticText: String {
        "失败阶段：\(stage.title) [\(stage.rawValue)]\n" + details.joined(separator: "\n")
    }

    public init(stage: Stage, underlying: Error) {
        // Cleanup must not replace an earlier, more precise failure stage.
        if let existing = underlying as? CaptureFailure { self = existing; return }
        self.stage = stage
        var lines: [String] = []
        var current: NSError? = underlying as NSError
        var visited = Set<ObjectIdentifier>()
        while let error = current, lines.count < 8, visited.insert(ObjectIdentifier(error)).inserted {
            let message = ASRChunk.sanitizedError(error.localizedDescription) ?? "系统未提供错误说明"
            let reason = ASRChunk.sanitizedError(error.localizedFailureReason)
            let suffix = reason.flatMap { $0 == message ? nil : "；" + $0 } ?? ""
            lines.append("\(error.domain) (\(error.code))：\(message)\(suffix)")
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        self.details = lines
    }
}

/// AVCaptureSession.startRunning() is synchronous but posts its runtime error
/// from another thread. Latch that error immediately, before a queued cleanup
/// can discard it. Each session owns a fresh latch, so old sessions cannot leak.
public final class CaptureSessionErrorLatch {
    private let lock = NSLock()
    private var firstError: Error?

    public init() {}

    public func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if firstError == nil { firstError = error }
    }

    public var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return firstError
    }
}
