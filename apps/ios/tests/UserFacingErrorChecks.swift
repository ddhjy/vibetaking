import Foundation

@main
struct UserFacingErrorChecks {
    static func main() {
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), name)
            print("PASS: \(name)")
        }

        check("credentials point to the actual settings section",
              UserFacingError.missingAICredentials.contains("连接 AI 服务"))
        check("invalid addresses include an example",
              UserFacingError.invalidAIAddress.contains("https://"))
        check("authentication failures require updating credentials",
              UserFacingError.aiHTTP(statusCode: 401).contains("密钥")
              && UserFacingError.aiHTTP(statusCode: 401).contains("重新填写"))
        check("missing models and endpoints point to both settings",
              UserFacingError.aiHTTP(statusCode: 404).contains("服务地址和模型 ID"))
        check("rate limits offer retry and quota recovery",
              UserFacingError.aiHTTP(statusCode: 429).contains("稍后")
              && UserFacingError.aiHTTP(statusCode: 429).contains("额度"))
        check("oversized requests have a different remedy from server failures",
              UserFacingError.aiHTTP(statusCode: 413).contains("分几次")
              && UserFacingError.aiHTTP(statusCode: 503).contains("服务商"))
        check("streamed errors use the same recovery as HTTP errors",
              UserFacingError.aiStream(code: "invalid_api_key") == UserFacingError.aiHTTP(statusCode: 401)
              && UserFacingError.aiStream(code: "context_length_exceeded") == UserFacingError.aiHTTP(statusCode: 413))
        check("unknown stream codes are not displayed as raw diagnostics",
              !UserFacingError.aiStream(code: "internal_secret_detail").contains("internal_secret_detail"))
        check("offline errors offer a network recovery path",
              URLError(.notConnectedToInternet).userFacingDescription.contains("连接网络"))
        check("certificate failures never suggest bypassing security",
              URLError(.serverCertificateUntrusted).userFacingDescription.contains("无法建立安全连接"))
        check("cancellation is consistent across Foundation and concurrency",
              URLError(.cancelled).userFacingDescription == CancellationError().userFacingDescription)
        check("file access and disk capacity failures have different recovery paths",
              CocoaError(.fileReadNoPermission).userFacingDescription.contains("可访问")
              && CocoaError(.fileWriteOutOfSpace).userFacingDescription.contains("释放"))
        let workflowError = NSError(domain: "WorkflowManager", code: -4,
                                    userInfo: [NSLocalizedDescriptionKey: "请先添加保存记录步骤。"])
        check("specific workflow instructions survive generic error mapping",
              workflowError.userFacingDescription == "请先添加保存记录步骤。")
    }
}
