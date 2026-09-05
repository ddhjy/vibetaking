import Foundation

nonisolated enum UserFacingError {
    static let missingAICredentials = "还没有连接 AI 服务。请到随心记“设置 → 连接 AI 服务”填写 AI 密钥。"
    static let invalidAIAddress = "AI 服务地址无法使用。请在设置中填写完整地址，例如 https://api.example.com/v1。"
    static let invalidAIResponse = "AI 服务没有返回可用内容。请检查设置中的服务地址和模型 ID，再试一次。"

    static func aiHTTP(statusCode: Int) -> String {
        switch statusCode {
        case 400, 422:
            return "AI 服务无法处理这次请求。请检查模型 ID，或缩短内容后再试一次。"
        case 401:
            return "AI 密钥未通过验证。请在设置中重新填写服务商提供的密钥。"
        case 403:
            return "当前 AI 服务拒绝了访问。请确认密钥有权使用所选模型，或联系服务商。"
        case 404:
            return "找不到所选 AI 接口或模型。请核对设置中的服务地址和模型 ID。"
        case 408, 504:
            return "AI 服务响应超时。请稍后再试，或缩短要处理的内容。"
        case 413:
            return "这次发送的内容超过 AI 服务限制。请缩短内容，或分几次处理。"
        case 429:
            return "AI 服务暂时限制了请求。请稍后再试；如果仍出现此提示，请向服务商检查可用额度。"
        case 500...599:
            return "AI 服务暂时不可用。请稍后再试；如果持续失败，请联系服务商。"
        default:
            return "AI 请求未完成（状态码 \(statusCode)）。请检查服务设置，或稍后再试。"
        }
    }

    static func aiStream(code: String) -> String {
        switch code {
        case "rate_limit_exceeded", "insufficient_quota": return aiHTTP(statusCode: 429)
        case "invalid_api_key", "authentication_error": return aiHTTP(statusCode: 401)
        case "permission_denied": return aiHTTP(statusCode: 403)
        case "model_not_found": return aiHTTP(statusCode: 404)
        case "context_length_exceeded": return aiHTTP(statusCode: 413)
        case "server_error": return aiHTTP(statusCode: 500)
        default: return "AI 服务未能完成这次请求。请检查模型设置，或稍后再试。"
        }
    }
}

extension Error {
    nonisolated var userFacingDescription: String {
        if self is CancellationError { return "操作已取消" }
        let error = self as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileReadNoSuchFile, .fileNoSuchFile:
                return "找不到这个文件。请在“文件”App 中确认文件仍在原处，然后重新选择。"
            case .fileReadNoPermission, .fileWriteNoPermission:
                return "暂时无法访问这个文件或位置。请在“文件”App 中选择可访问的文件或保存位置。"
            case .fileWriteOutOfSpace:
                return "可用存储空间不足。请释放一些空间后再试一次。"
            case .fileReadCorruptFile:
                return "这个文件无法读取。请重新下载或导出后再试一次。"
            default:
                return "文件操作未完成。请检查文件是否可访问及可用存储空间，再试一次。"
            }
        }
        guard error.domain == NSURLErrorDomain else { return localizedDescription }
        switch URLError.Code(rawValue: error.code) {
        case .notConnectedToInternet:
            return "当前没有网络连接。请连接网络后再试一次。"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "无法连接接收端或服务。请检查网络、地址，以及接收端是否已打开，再试一次。"
        case .timedOut:
            return "等待响应超时。请检查网络，稍后再试一次。"
        case .networkConnectionLost:
            return "网络连接已中断。请恢复网络后再试一次。"
        case .badURL, .unsupportedURL:
            return "服务地址无法使用。AI 服务需填写完整的 https:// 地址；发送到 Mac 时请检查主机和端口。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "无法建立安全连接。请核对服务地址；如果地址无误，请联系服务提供方。"
        case .cancelled:
            return "操作已取消"
        default:
            return "暂时无法连接服务。请检查网络和服务地址后再试一次。"
        }
    }
}
