import Foundation

nonisolated struct TagRecommendationExample: Sendable {
    let text: String
    let tags: [String]
    let createdAt: Date
}

@MainActor
@Observable
class AIService {
    static let shared = AIService()

    private init() {}

    func fetchModels() async throws -> [AIModel] {
        guard let token = SettingsManager.shared.aiApiToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw AIServiceError.missingToken
        }

        let url = try endpointURL(path: "models")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let result = try decode(AIModelsResponse.self, from: data)
        return result.data
    }
    
    func process(text: String, prompt: String) async throws -> String {
        guard let token = SettingsManager.shared.aiApiToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw AIServiceError.missingToken
        }
        
        let url = try endpointURL(path: "responses")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        
        let selectedModelID = SettingsManager.shared.aiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = selectedModelID.isEmpty
            ? SettingsManager.defaultAIModelID
            : selectedModelID
        
        let body: [String: Any] = [
            "model": modelID,
            "instructions": prompt,
            "input": text,
            "stream": false,
            "temperature": 0.7,
            "max_output_tokens": 4096
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        
        let result = try decode(AIResponse.self, from: data)
        let content = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !content.isEmpty else {
            throw AIServiceError.emptyResponse
        }
        
        return content
    }

    func recommendTags(
        for text: String,
        from availableTags: [String],
        historyExamples: [TagRecommendationExample] = [],
        maxCount: Int = 8
    ) async throws -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return [] }

        let cleanedTags = availableTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleanedTags.isEmpty else { return [] }

        let uniqueTags = Array(Set(cleanedTags)).sorted()
        let limitedCount = max(1, min(maxCount, uniqueTags.count))
        let historySection = buildHistoryExamplesSection(
            for: trimmedText,
            candidates: uniqueTags,
            historyExamples: historyExamples
        )

        let prompt = """
        你是标签推荐器。请根据正文内容，从候选标签中选出最相关的标签并按相关性从高到低排序。

        要求：
        1. 只能从候选标签中选择，不能新增、改写或合并标签。
        2. 最多返回 \(limitedCount) 个标签。
        3. 历史打标样例代表用户过往的个人标签语义，只能辅助判断；如果历史样例与当前正文冲突，以当前正文为准。
        4. 只返回 JSON 数组，例如 ["标签A","标签B"]，不要输出其它文字。

        \(historySection)

        候选标签：
        \(uniqueTags.joined(separator: " | "))
        """

        let raw = try await process(text: trimmedText, prompt: prompt)
        return parseRecommendedTags(raw, candidates: uniqueTags, maxCount: limitedCount)
    }

    private func parseRecommendedTags(_ raw: String, candidates: [String], maxCount: Int) -> [String] {
        var candidateMap: [String: String] = [:]
        for candidate in candidates {
            let key = candidate.lowercased()
            if candidateMap[key] == nil {
                candidateMap[key] = candidate
            }
        }
        var seen = Set<String>()
        var results: [String] = []

        func appendIfMatch(_ token: String) {
            let normalized = token
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]"))
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard !normalized.isEmpty else { return }
            guard let matched = candidateMap[normalized.lowercased()] else { return }
            guard !seen.contains(matched) else { return }
            seen.insert(matched)
            results.append(matched)
        }

        let cleaned = raw
            .replacing("```json", with: "")
            .replacing("```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = cleaned.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            for token in decoded {
                appendIfMatch(token)
                if results.count >= maxCount { return results }
            }
            return results
        }

        let separators = CharacterSet(charactersIn: ",\n")
        for part in cleaned.components(separatedBy: separators) {
            appendIfMatch(part)
            if results.count >= maxCount { break }
        }

        return results
    }

    private struct SelectedTagRecommendationExample {
        let excerpt: String
        let tags: [String]
    }

    private func buildHistoryExamplesSection(
        for text: String,
        candidates: [String],
        historyExamples: [TagRecommendationExample]
    ) -> String {
        let selectedExamples = selectRelevantHistoryExamples(
            for: text,
            candidates: candidates,
            historyExamples: historyExamples
        )
        guard !selectedExamples.isEmpty else { return "" }

        let examplesText = selectedExamples.enumerated().map { index, example in
            """
            样例 \(index + 1)
            标签：\(example.tags.joined(separator: "、"))
            文本摘录：\(example.excerpt)
            """
        }.joined(separator: "\n\n")

        return """
        历史打标样例：
        \(examplesText)
        """
    }

    private func selectRelevantHistoryExamples(
        for text: String,
        candidates: [String],
        historyExamples: [TagRecommendationExample],
        maxExamples: Int = 12,
        maxExamplesPerTag: Int = 2,
        maxExcerptLength: Int = 160
    ) -> [SelectedTagRecommendationExample] {
        let candidateSet = Set(candidates)
        let currentTokens = normalizedTokens(from: text)
        guard !currentTokens.isEmpty else { return [] }

        let now = Date()
        let scoredExamples = historyExamples.compactMap { example -> (example: TagRecommendationExample, tags: [String], score: Double)? in
            let tags = cleanedTags(from: example.tags, candidateSet: candidateSet)
            guard !tags.isEmpty else { return nil }

            let exampleTokens = normalizedTokens(from: example.text)
            guard !exampleTokens.isEmpty else { return nil }

            let overlapCount = currentTokens.intersection(exampleTokens).count
            guard overlapCount > 0 else { return nil }

            let unionCount = currentTokens.union(exampleTokens).count
            let similarity = Double(overlapCount) / Double(max(unionCount, 1))
            let ageInDays = max(0, now.timeIntervalSince(example.createdAt)) / 86_400
            let recencyScore = 1 / (1 + ageInDays / 30)
            let score = similarity * 0.8 + recencyScore * 0.2

            return (example, tags, score)
        }
        .sorted {
            if $0.score != $1.score {
                return $0.score > $1.score
            }
            return $0.example.createdAt > $1.example.createdAt
        }

        var selectedExamples: [SelectedTagRecommendationExample] = []
        var exampleCountByTag: [String: Int] = [:]

        for scoredExample in scoredExamples {
            let availableTags = scoredExample.tags.filter {
                exampleCountByTag[$0, default: 0] < maxExamplesPerTag
            }
            guard !availableTags.isEmpty else { continue }

            selectedExamples.append(
                SelectedTagRecommendationExample(
                    excerpt: excerpt(from: scoredExample.example.text, maxLength: maxExcerptLength),
                    tags: availableTags
                )
            )

            for tag in availableTags {
                exampleCountByTag[tag, default: 0] += 1
            }

            if selectedExamples.count >= maxExamples {
                break
            }
        }

        return selectedExamples
    }

    private func cleanedTags(from tags: [String], candidateSet: Set<String>) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidateSet.contains(trimmedTag), !seen.contains(trimmedTag) else { return nil }
            seen.insert(trimmedTag)
            return trimmedTag
        }
    }

    private func normalizedTokens(from text: String) -> Set<String> {
        var tokens = Set<String>()
        var wordRun = ""
        var cjkRun: [String] = []

        func flushWordRun() {
            let token = wordRun.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.count >= 2 {
                tokens.insert(token)
            }
            wordRun = ""
        }

        func flushCJKRun() {
            if cjkRun.count == 1 {
                tokens.insert(cjkRun[0])
            } else if cjkRun.count > 1 {
                for index in 0..<(cjkRun.count - 1) {
                    tokens.insert(cjkRun[index] + cjkRun[index + 1])
                }
            }
            cjkRun = []
        }

        for scalar in text.lowercased().unicodeScalars {
            if isCJK(scalar) {
                flushWordRun()
                cjkRun.append(String(scalar))
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJKRun()
                wordRun.unicodeScalars.append(scalar)
            } else {
                flushWordRun()
                flushCJKRun()
            }
        }

        flushWordRun()
        flushCJKRun()

        return tokens
    }

    private func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF:
            return true
        default:
            return false
        }
    }

    private func excerpt(from text: String, maxLength: Int) -> String {
        let condensedText = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard condensedText.count > maxLength else { return condensedText }
        return String(condensedText.prefix(maxLength)) + "..."
    }

    private func endpointURL(path: String) throws -> URL {
        let baseURLString = SettingsManager.normalizedAIBaseURLString(SettingsManager.shared.aiBaseURLString)
        let endpointString = "\(baseURLString)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"

        guard let url = URL(string: endpointString) else {
            throw AIServiceError.invalidURL
        }

        return url
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.requestFailed(nil)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = formatHTTPError(statusCode: httpResponse.statusCode, data: data)
            throw AIServiceError.requestFailed(message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let message = decodeErrorMessage(from: data) ?? "服务返回内容无法解析"
            throw AIServiceError.invalidResponse(message)
        }
    }

    private func formatHTTPError(statusCode: Int, data: Data) -> String {
        let message = decodeErrorMessage(from: data) ?? "HTTP \(statusCode)"
        return message.hasPrefix("HTTP ") ? message : "HTTP \(statusCode)，\(message)"
    }

    private func decodeErrorMessage(from data: Data) -> String? {
        if let gatewayError = try? JSONDecoder().decode(AIGatewayErrorResponse.self, from: data) {
            return gatewayError.message
        }

        if let apiError = try? JSONDecoder().decode(AIAPIErrorResponse.self, from: data) {
            return apiError.error.message
        }

        guard let body = String(data: data, encoding: .utf8) else { return nil }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return nil }

        if trimmedBody.localizedCaseInsensitiveContains("error code: 1033")
            || trimmedBody.localizedCaseInsensitiveContains("cloudflare tunnel error") {
            return "Sub2API 网关暂不可用（Cloudflare 1033），请检查 API 域名或隧道是否在线"
        }

        if trimmedBody.localizedCaseInsensitiveContains("<!doctype html")
            || trimmedBody.localizedCaseInsensitiveContains("<html") {
            return "服务返回了 HTML 错误页，请检查 Sub2API 网关地址是否可用"
        }

        return String(trimmedBody.prefix(180))
    }
}

enum AIServiceError: LocalizedError {
    case missingToken
    case invalidURL
    case requestFailed(String?)
    case invalidResponse(String?)
    case emptyResponse
    
    var errorDescription: String? {
        switch self {
        case .missingToken: return "请先在设置中填写 AI 密钥"
        case .invalidURL: return "AI 服务地址异常，请联系管理员"
        case .requestFailed(let message):
            if let message, !message.isEmpty {
                return "AI 请求失败：\(message)"
            }
            return "AI 请求失败，请稍后重试"
        case .invalidResponse(let message):
            if let message, !message.isEmpty {
                return "AI 返回异常：\(message)"
            }
            return "AI 返回内容异常，请检查服务配置"
        case .emptyResponse: return "AI 未返回结果，请调整提示词后重试"
        }
    }
}

struct AIResponse: Codable {
    let output: [OutputItem]
    let outputTextValue: String?

    var outputText: String {
        if let outputTextValue, !outputTextValue.isEmpty {
            return outputTextValue
        }

        return output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text)
            .joined()
    }

    enum CodingKeys: String, CodingKey {
        case output
        case outputTextValue = "output_text"
    }

    struct OutputItem: Codable {
        let type: String
        let content: [OutputContent]?
    }
    
    struct OutputContent: Codable {
        let type: String
        let text: String?
    }
}

struct AIModel: Codable, Hashable, Identifiable {
    let id: String
    let displayName: String?

    var title: String {
        guard let displayName, !displayName.isEmpty else { return id }
        return displayName
    }

    var supportsTextGeneration: Bool {
        !id.localizedCaseInsensitiveContains("image")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

private struct AIModelsResponse: Codable {
    let data: [AIModel]
}

private struct AIAPIErrorResponse: Codable {
    let error: AIAPIError

    struct AIAPIError: Codable {
        let message: String
    }
}

private struct AIGatewayErrorResponse: Codable {
    let message: String
}
