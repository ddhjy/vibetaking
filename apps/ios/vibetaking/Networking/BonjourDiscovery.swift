import Foundation
import Network
import Observation

enum VibetakingBonjour {
    static let serviceType = "_vibetaking._tcp"
    static let domain = "local."
}

struct DiscoveredDevice: Identifiable, Hashable {
    let serviceName: String
    var id: String { serviceName }
}

enum DeviceDiscoveryStatus: Equatable {
    case idle
    case searching
    case ready
    case failed(String)
}

@MainActor
@Observable
final class DeviceDiscoveryManager {
    static let shared = DeviceDiscoveryManager()

    private(set) var devices: [DiscoveredDevice] = []
    private(set) var status: DeviceDiscoveryStatus = .idle

    private var browser: NWBrowser?
    private var refCount = 0

    func start() {
        refCount += 1
        guard browser == nil else { return }

        status = .searching
        devices = []

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: VibetakingBonjour.serviceType, domain: VibetakingBonjour.domain),
            using: params
        )

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = .ready
                case .failed(let error):
                    self.status = .failed(error.localizedDescription)
                case .waiting:
                    break
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return name
            }
            Task { @MainActor in
                self?.devices = names.sorted().map(DiscoveredDevice.init(serviceName:))
                if self?.status == .searching {
                    self?.status = .ready
                }
            }
        }

        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        browser?.cancel()
        browser = nil
        devices = []
        status = .idle
    }
}

enum HTTPTargetURL {
    static func make(host: String, port: Int, path: String = "/") -> URL? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, (1 ... 65_535).contains(port),
              !trimmedHost.contains(where: { $0.isWhitespace || "/?#@".contains($0) }) else { return nil }

        var hostPart = trimmedHost
        if let zoneIndex = hostPart.firstIndex(of: "%") {
            hostPart = String(hostPart[..<zoneIndex])
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = hostPart
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }
}

enum BonjourResolver {
    struct Resolved: Sendable, Equatable {
        let host: String
        let port: Int
    }

    static func resolve(serviceName: String, timeout: TimeInterval = 3) async -> Resolved? {
        let endpoint = NWEndpoint.service(
            name: serviceName,
            type: VibetakingBonjour.serviceType,
            domain: VibetakingBonjour.domain,
            interface: nil
        )

        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "cn.1pointech.vibetaking.bonjour-resolver")

        return await withCheckedContinuation { continuation in
            var didFinish = false
            let finish: (Resolved?) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        let hostString = Self.string(from: host)
                        if Self.isUsableHost(hostString) {
                            finish(Resolved(host: hostString, port: Int(port.rawValue)))
                        } else {
                            finish(nil)
                        }
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    private static func isUsableHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return HTTPTargetURL.make(host: trimmed, port: 1) != nil
    }

    private static func string(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            let raw = "\(address)"
            return raw.split(separator: "%").first.map(String.init) ?? raw
        @unknown default:
            return "\(host)"
        }
    }
}
