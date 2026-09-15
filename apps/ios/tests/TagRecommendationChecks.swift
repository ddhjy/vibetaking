import Foundation

// Compile the production service without reading app settings or credentials.
@MainActor final class SettingsManager {
    static let shared = SettingsManager()
    static let defaultAIModelID = "test-model"
    var aiApiToken: String?
    var aiBaseURLString = "https://vibetaking.test/v1"
    var aiModelID = defaultAIModelID
    static func normalizedAIBaseURLString(_ value: String) -> String { value }
}

nonisolated final class RecommendationResponse: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var capturedPrompt = ""

    static var prompt: String {
        lock.lock()
        defer { lock.unlock() }
        return capturedPrompt
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        precondition(request.url?.host == "vibetaking.test")
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        Self.lock.lock()
        Self.capturedPrompt = payload["instructions"] as! String
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let data = try! JSONSerialization.data(withJSONObject: [
            "output": [],
            "output_text": "```json\n[\"灵感\",\"候选之外\",\"工作\",\"灵感\"]\n```"
        ])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor private final class Heartbeat {
    var isPreparing = false
    var ticksWhilePreparing = 0
    var maxGap = 0.0
    private var last = ProcessInfo.processInfo.systemUptime

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        maxGap = max(maxGap, now - last)
        last = now
        if isPreparing { ticksWhilePreparing += 1 }
    }
}

@main struct TagRecommendationChecks {
    @MainActor static func main() async throws {
        URLProtocol.registerClass(RecommendationResponse.self)
        defer { URLProtocol.unregisterClass(RecommendationResponse.self) }

        let text = "知识库要解决的问题有两类：领域知识缺失、事实知识缺失。每个例子代表长期记录、工作复盘和个人想法。"
        let examples = (0..<200).map { index in
            TagRecommendationExample(
                text: String(repeating: text, count: 80) + String(index),
                tags: ["工作", "灵感"],
                createdAt: Date().addingTimeInterval(Double(-index))
            )
        }

        let heartbeat = Heartbeat()
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                heartbeat.tick()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        heartbeat.isPreparing = true
        do {
            _ = try await AIService.shared.recommendTags(for: text, from: ["工作", "灵感"], historyExamples: examples)
            preconditionFailure("Missing credentials must stop the request")
        } catch AIServiceError.missingToken {}
        heartbeat.isPreparing = false
        monitor.cancel()
        precondition(heartbeat.ticksWhilePreparing > 0, "History scoring blocked MainActor")
        print(String(format: "PASS: MainActor remains responsive during scoring (largest heartbeat gap %.1f ms)", heartbeat.maxGap * 1000))

        let cancelled = Task { @MainActor in
            try await AIService.shared.recommendTags(for: text, from: ["工作", "灵感"], historyExamples: examples)
        }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelled scoring must stop")
        } catch is CancellationError {}
        print("PASS: Cancelling recommendation interrupts preparation before the request")

        SettingsManager.shared.aiApiToken = "test-only"
        let result = try await AIService.shared.recommendTags(
            for: text,
            from: [" 灵感 ", "工作", "灵感"],
            historyExamples: examples
        )
        precondition(result == ["灵感", "工作"], "Candidate filtering and ordering changed")
        precondition(RecommendationResponse.prompt.contains("样例 1"))
        precondition(RecommendationResponse.prompt.contains("样例 2"))
        precondition(!RecommendationResponse.prompt.contains("样例 3"), "Per-tag example limit changed")
        precondition(RecommendationResponse.prompt.contains("工作 | 灵感"), "Candidate cleanup changed")
        print("PASS: History examples, candidate cleanup, response filtering and ordering are preserved")
    }
}
