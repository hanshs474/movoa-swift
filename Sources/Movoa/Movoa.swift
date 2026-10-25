import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Official Swift SDK for Movoa (https://movoa.ai), the AI video generator with sound.
///
/// Create an API key at https://movoa.ai/settings/apikeys and pass it in, or set
/// `MOVOA_API_KEY`. Runs cost credits on your Movoa account, at the prices on
/// https://movoa.ai/pricing.
///
///     let movoa = Movoa()
///     let clip = try await movoa.generateVideo("a lighthouse in a storm, waves crashing, thunder")
///     let fromPhoto = try await movoa.generateVideo("the statue turns its head",
///                                                   imageURL: "https://example.com/statue.jpg")
public struct Movoa {
    public static let defaultBaseURL = URL(string: "https://movoa.ai")!
    public static let keysURL = "https://movoa.ai/settings/apikeys"
    public static let defaultModel = "minimax-h3"
    public static let version = "0.1.0"
    static let keyHint = "Create a key at \(keysURL) and set MOVOA_API_KEY."

    public enum MovoaError: Error, LocalizedError, Equatable {
        /// No API key, or the key is wrong or deleted.
        case auth(String)
        /// The content filter refused the prompt, or the account is cooling down after a refusal. Reword rather than retry.
        case rejected(String)
        /// Not enough credits left on the account for this run.
        case quota(String)
        /// This model or quality needs a plan, or the account has not bought credits yet.
        case plan(String)
        /// Another generation on this account is still running.
        case busy(String)
        /// The run was accepted and then failed or was canceled.
        case generation(taskId: String, message: String, errorMessage: String?, failureKind: String?)
        /// The wait ran out; the run may still finish. Look it up later with `status(_:)`.
        case timeout(taskId: String)
        /// Anything else: a network failure, a 5xx, a non-JSON answer, another refusal.
        case api(status: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .auth(let m): return "movoa: \(m)"
            case .rejected(let m): return "movoa: the request was refused: \(m)"
            case .quota(let m): return "movoa: not enough credits: \(m)"
            case .plan(let m): return "movoa: this model or quality needs a plan: \(m)"
            case .busy(let m): return "movoa: another generation is still running: \(m)"
            case .generation(_, let m, _, _): return "movoa: \(m)"
            case .timeout(let id): return "movoa: run \(id) is still generating; check it later with status(\"\(id)\")"
            case .api(let s, let m): return "movoa: \(m) (HTTP \(s))"
            }
        }
    }

    /// One run as `/api/ai/query` reports it.
    public struct Status {
        public let id: String
        /// "pending", "processing", "success", "failed" or "canceled".
        public let status: String
        /// The finished clips once `status` is "success".
        public let videos: [URL]
        public let errorMessage: String?
        public let failureKind: String?
        /// True while the run waits in the queue.
        public let queued: Bool
        /// Estimated seconds left in the queue.
        public let queueEta: Int?

        /// The first finished clip.
        public var videoURL: URL? { videos.first }
        public var isSuccess: Bool { status == "success" }
        public var isFailed: Bool { status == "failed" || status == "canceled" }

        init(_ d: [String: Any]) {
            id = d["id"].map { "\($0)" } ?? ""
            status = d["status"] as? String ?? ""
            videos = (d["videos"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(URL.init(string:)) }
            errorMessage = d["errorMessage"] as? String
            failureKind = d["failureKind"] as? String
            queued = d["queued"] as? Bool ?? false
            queueEta = (d["queueEta"] as? NSNumber)?.intValue
        }
    }

    public let apiKey: String
    public let baseURL: URL
    public let session: URLSession
    /// Seconds between status checks while waiting.
    public var pollInterval: TimeInterval = 10
    /// Total seconds `generateVideo` waits for a run; a queued run can take a while.
    public var timeout: TimeInterval = 1800

    /// A missing key reads `MOVOA_API_KEY`; a missing base URL reads `MOVOA_BASE_URL`, then https://movoa.ai.
    public init(apiKey: String? = nil, baseURL: URL? = nil, session: URLSession = .shared) {
        let env = ProcessInfo.processInfo.environment
        self.apiKey = (apiKey ?? env["MOVOA_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL ?? env["MOVOA_BASE_URL"].flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? Movoa.defaultBaseURL
        self.session = session
    }

    /// Generate one clip with sound and return the URL of the finished file.
    ///
    /// `imageURL` (a public https image) makes it photo to video, with the image as the first frame.
    /// `options` go to the model as-is, e.g. `["duration": 8, "resolution": "768p", "aspect_ratio": "9:16"]`.
    public func generateVideo(_ prompt: String, model: String = Movoa.defaultModel, imageURL: String? = nil,
                              options: [String: Any] = [:]) async throws -> URL {
        let id = try await submit(prompt, model: model, imageURL: imageURL, options: options)
        guard let url = try await wait(id).videoURL else {
            throw MovoaError.generation(taskId: id, message: "run \(id) finished with no video", errorMessage: nil, failureKind: nil)
        }
        return url
    }

    /// Start a run and return its id without waiting.
    public func submit(_ prompt: String, model: String = Movoa.defaultModel, imageURL: String? = nil,
                       options: [String: Any] = [:]) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MovoaError.api(status: 0, message: "prompt is required")
        }
        let data = try await post("/api/ai/generate", Movoa.submitBody(prompt, model: model, imageURL: imageURL, options: options))
        guard let d = data as? [String: Any], let id = d["id"], !"\(id)".isEmpty else {
            throw MovoaError.api(status: 200, message: "movoa.ai accepted the run but returned no id")
        }
        return "\(id)"
    }

    /// Look up a run.
    public func status(_ id: String) async throws -> Status {
        Status(try await post("/api/ai/query", ["taskId": id]) as? [String: Any] ?? [:])
    }

    /// Credits left on the account.
    public func credits() async throws -> Int {
        guard let d = try await post("/api/user/get-user-credits", [:]) as? [String: Any],
              let n = d["remainingCredits"] as? NSNumber else {
            throw MovoaError.api(status: 200, message: "movoa.ai returned no credit balance")
        }
        return n.intValue
    }

    /// Poll a submitted run until it succeeds. Throws `.generation` when it fails or is canceled,
    /// `.timeout` when `timeout` runs out.
    public func wait(_ id: String) async throws -> Status {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var st: Status?
            do { st = try await status(id) } catch MovoaError.api { /* only a dropped poll is retried */ }
            if let st = st, st.isSuccess, st.videoURL != nil { return st }
            if let st = st, st.isFailed || st.isSuccess {
                let why = st.errorMessage.map { ": \($0)" } ?? (st.isSuccess ? " with no video" : "")
                throw MovoaError.generation(taskId: id, message: "run \(id) \(st.status)\(why)",
                                            errorMessage: st.errorMessage, failureKind: st.failureKind)
            }
            if Date().addingTimeInterval(pollInterval) > deadline { throw MovoaError.timeout(taskId: id) }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func post(_ path: String, _ payload: [String: Any]) async throws -> Any? {
        guard !apiKey.isEmpty else { throw MovoaError.auth("No API key set. \(Movoa.keyHint)") }
        var req = URLRequest(url: URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        req.setValue("movoa-swift/\(Movoa.version)", forHTTPHeaderField: "user-agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data: Data, res: URLResponse
        do { (data, res) = try await session.data(for: req) } catch {
            throw MovoaError.api(status: 0, message: "Could not reach movoa.ai: \(error.localizedDescription)")
        }
        return try Movoa.check((res as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
    }

    // MARK: - Request and response shapes (public so they can be tested without the network)

    /// The body of `POST /api/ai/generate`.
    public static func submitBody(_ prompt: String, model: String = Movoa.defaultModel, imageURL: String? = nil,
                                  options: [String: Any] = [:]) -> [String: Any] {
        var opts = options
        opts["sound"] = true
        let i2v = !(imageURL ?? "").isEmpty
        if i2v { opts["image_input"] = [imageURL!] }
        return [
            "provider": "auto", // the service routes by model; this only has to be non-empty
            "mediaType": "video",
            "model": model,
            "scene": i2v ? "image-to-video" : "text-to-video",
            "prompt": prompt,
            "options": opts,
        ]
    }

    /// Map one answer to its `data`, or throw the matching error. movoa.ai answers almost every refusal
    /// as HTTP 200 with a non-zero `code` and a `data.reason`, so the status code alone reads a refusal as success.
    public static func check(_ status: Int, _ body: Any?) throws -> Any? {
        let b = body as? [String: Any]
        if status == 401 { throw MovoaError.auth(b?["message"] as? String ?? "Invalid API key. \(keyHint)") }
        guard let body = b else { throw MovoaError.api(status: status, message: "movoa.ai returned a non-JSON response") }
        let code = (body["code"] as? NSNumber)?.intValue
        if code == 0 { return body["data"] }
        let msg = body["message"] as? String ?? "request failed"
        if code == -2 || code == -3 { throw MovoaError.rejected(msg) }
        switch (body["data"] as? [String: Any])?["reason"] as? String {
        case "insufficient_credits": throw MovoaError.quota(msg)
        case "plan_required": throw MovoaError.plan(msg)
        case "concurrency": throw MovoaError.busy(msg)
        default: break
        }
        if msg.lowercased().contains("no auth") { throw MovoaError.auth("\(msg). \(keyHint)") }
        throw MovoaError.api(status: status, message: msg)
    }
}
