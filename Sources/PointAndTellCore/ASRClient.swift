import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol ASRCancellable: AnyObject {
    func cancel()
}

public struct ASRHTTPResponse {
    public let statusCode: Int
    public let data: Data
    public let contentType: String?

    public init(statusCode: Int, data: Data, contentType: String? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.contentType = contentType
    }
}

public protocol ASRTransport {
    @discardableResult
    func send(_ request: URLRequest,
              completion: @escaping (Result<ASRHTTPResponse, Error>) -> Void) -> ASRCancellable
}

public enum ASRRequestBuilder {
    public static func makeRequest(wav: Data, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ASRError.missingAPIKey }
        // Header injection and accidentally pasted multiline keys are rejected.
        guard key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw ASRError.invalidAPIKey
        }
        let audio = try ASRWAVAudio(wav: wav)
        try audio.validateForRequest()
        let dataURI = ASRWAVAudio.dataURIPrefix + wav.base64EncodedString()
        let body: [String: Any] = [
            "model": ASRProvider.model,
            "input": ["messages": [[
                "role": "user",
                "content": [["type": "input_audio", "input_audio": ["data": dataURI]]]
            ]]],
            "parameters": ["format": "wav", "sample_rate": "16000"]
        ]
        var request = URLRequest(url: ASRProvider.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(audio.durationSeconds >= 60 ? "enable" : "disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

/// macOS 11-compatible completion-handler transport; no async URLSession APIs.
/// Responses are buffered until completion, then SSE finals are normalized.
public final class ASRURLSessionTransport: ASRTransport {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: ASRRedirectBlocker(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    @discardableResult
    public func send(_ request: URLRequest,
                     completion: @escaping (Result<ASRHTTPResponse, Error>) -> Void) -> ASRCancellable {
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(ASRError.invalidHTTPResponse)); return
            }
            completion(.success(ASRHTTPResponse(statusCode: response.statusCode, data: data ?? Data(),
                                                contentType: response.value(forHTTPHeaderField: "Content-Type"))))
        }
        task.resume()
        return ASRTaskHandle(task: task)
    }
}

private final class ASRRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward the user's audio or key to a redirected destination.
        completionHandler(nil)
    }
}

private final class ASRTaskHandle: ASRCancellable {
    let task: URLSessionDataTask
    init(task: URLSessionDataTask) { self.task = task }
    func cancel() { task.cancel() }
}

public final class ASRClient {
    private let transport: ASRTransport
    private let callbackQueue: DispatchQueue

    public init(transport: ASRTransport = ASRURLSessionTransport(), callbackQueue: DispatchQueue = .main) {
        self.transport = transport
        self.callbackQueue = callbackQueue
    }

    /// Sends exactly one normalized audio chunk. Never retries automatically;
    /// job persistence and explicit retry decisions belong to the caller.
    @discardableResult
    public func transcribe(wav: Data, apiKey: String,
                           completion: @escaping (Result<[ASRSentence], Error>) -> Void) -> ASRCancellable {
        let operation = ASROperation(queue: callbackQueue, completion: completion)
        do {
            let request = try ASRRequestBuilder.makeRequest(wav: wav, apiKey: apiKey)
            let task = transport.send(request) { result in
                let parsed: Result<[ASRSentence], Error> = result.flatMap { response in
                    guard (200..<300).contains(response.statusCode) else {
                        let metadata = ASRResponseParser.errorMetadata(response.data)
                        return .failure(ASRError.httpStatus(response.statusCode, code: metadata.code, requestID: metadata.requestID))
                    }
                    return Result {
                        try ASRResponseParser.parse(data: response.data, contentType: response.contentType).sentences
                    }
                }
                operation.finish(parsed)
            }
            operation.attach(task)
        } catch { operation.finish(.failure(error)) }
        return operation
    }
}

private final class ASROperation: ASRCancellable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var completion: ((Result<[ASRSentence], Error>) -> Void)?
    private var task: ASRCancellable?

    init(queue: DispatchQueue, completion: @escaping (Result<[ASRSentence], Error>) -> Void) {
        self.queue = queue
        self.completion = completion
    }

    func attach(_ task: ASRCancellable) {
        lock.lock()
        let alreadyFinished = completion == nil
        if !alreadyFinished { self.task = task }
        lock.unlock()
        if alreadyFinished { task.cancel() }
    }

    func finish(_ result: Result<[ASRSentence], Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        task = nil
        lock.unlock()
        if let callback = callback { queue.async { callback(result) } }
    }

    func cancel() {
        lock.lock()
        let callback = completion
        let pendingTask = task
        completion = nil
        task = nil
        lock.unlock()
        pendingTask?.cancel()
        if let callback = callback { queue.async { callback(.failure(URLError(.cancelled))) } }
    }
}
