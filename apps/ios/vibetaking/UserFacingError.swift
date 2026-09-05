import Foundation

extension Error {
    var userFacingDescription: String {
        let error = self as NSError
        guard error.domain == NSURLErrorDomain else { return localizedDescription }
        switch URLError.Code(rawValue: error.code) {
        case .notConnectedToInternet:
            return "当前未连接网络，请连接网络后重试。"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "无法连接服务器，请检查服务器地址与网络后重试。"
        case .timedOut:
            return "请求超时，请稍后重试。"
        case .networkConnectionLost:
            return "网络连接已中断，请重试。"
        case .badURL, .unsupportedURL:
            return "服务器地址无效，请使用完整的 http:// 或 https:// 地址。"
        case .cancelled:
            return "已取消"
        default:
            return localizedDescription
        }
    }
}
