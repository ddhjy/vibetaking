import Foundation
import Network
import SwiftUI

@main
struct VibetakingApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await MainActor.run {
                        AutoPasteSyncManager.shared.handleScenePhaseChange(scenePhase)
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    Task { @MainActor in
                        AutoPasteSyncManager.shared.handleScenePhaseChange(newPhase)
                    }
                }
        }
    }
}

@MainActor
final class AutoPasteSyncManager {
    static let shared = AutoPasteSyncManager()

    private let callbackPort: UInt16 = 7789
    private let controlServer = VibetakingControlServer()

    private var isSceneActive = false
    private var lastActiveTargets: Set<SyncTarget> = []
    private var pendingDraftSync: DraftSyncState?
    private var syncTask: Task<Void, Never>?
    private var lastDeliveredDraftSync: DraftSyncState?
    private var consecutiveSyncFailures = 0

    private init() {
        controlServer.onClearDraft = { [weak self] in
            Task { @MainActor in
                self?.handleRemoteDraftClear()
            }
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        let currentTargets = Set(activeSyncTargets)
        let isActive = phase == .active
        if isSceneActive == isActive {
            if isActive && !currentTargets.isEmpty {
                lastActiveTargets = currentTargets
                startControlServerIfNeeded()
                syncCurrentDraft()
            }
            return
        }

        isSceneActive = isActive

        guard isActive else {
            controlServer.stop()
            lastActiveTargets = currentTargets
            pendingDraftSync = nil
            consecutiveSyncFailures = 0
            return
        }

        guard !currentTargets.isEmpty else {
            lastActiveTargets = currentTargets
            return
        }
        lastActiveTargets = currentTargets
        startControlServerIfNeeded()
        syncCurrentDraft(force: true)
    }

    func settingsDidChange() {
        let currentTargets = Set(activeSyncTargets)
        let removedTargets = Array(lastActiveTargets.subtracting(currentTargets))

        guard isSceneActive else {
            lastActiveTargets = currentTargets
            return
        }

        if !currentTargets.isEmpty {
            startControlServerIfNeeded()
            syncCurrentDraft(force: true)
        } else {
            controlServer.stop()
            pendingDraftSync = nil
        }

        if !removedTargets.isEmpty {
            Task {
                _ = await sendDraft(text: "", to: removedTargets)
            }
        }

        lastDeliveredDraftSync = nil
        lastActiveTargets = currentTargets
    }

    func scheduleDraftSync(text: String, force: Bool = false) {
        guard isSceneActive else { return }

        let targets = activeSyncTargets
        guard !targets.isEmpty else { return }

        lastActiveTargets = Set(targets)
        let syncState = DraftSyncState(text: text, targets: Set(targets))
        if !force,
           syncState == lastDeliveredDraftSync,
           pendingDraftSync == nil {
            return
        }

        pendingDraftSync = syncState
        startSyncTaskIfNeeded()
    }

    private func syncCurrentDraft(force: Bool = false) {
        scheduleDraftSync(text: HistoryManager.shared.currentDraft.text, force: force)
    }

    private func startControlServerIfNeeded() {
        controlServer.start(port: callbackPort)
    }

    private func handleRemoteDraftClear() {
        HistoryManager.shared.clearDraft()
    }

    private func startSyncTaskIfNeeded() {
        guard syncTask == nil else { return }

        syncTask = Task { [weak self] in
            await self?.drainPendingDraftSyncs()
        }
    }

    private func drainPendingDraftSyncs() async {
        defer {
            syncTask = nil

            if isSceneActive, pendingDraftSync != nil {
                startSyncTaskIfNeeded()
            }
        }

        while !Task.isCancelled {
            guard isSceneActive else { return }
            guard let syncState = pendingDraftSync else { return }

            if syncState == lastDeliveredDraftSync {
                pendingDraftSync = nil
                continue
            }

            let didSucceed = await sendDraft(text: syncState.text, to: Array(syncState.targets))
            guard !Task.isCancelled else { return }

            if didSucceed {
                if pendingDraftSync == syncState {
                    pendingDraftSync = nil
                }
                lastDeliveredDraftSync = syncState
                consecutiveSyncFailures = 0
                continue
            }

            consecutiveSyncFailures += 1
            let retryDelayNanoseconds = UInt64(
                min(
                    pow(2.0, Double(consecutiveSyncFailures - 1)) * 350_000_000,
                    5_000_000_000
                )
            )
            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
    }

    private func sendDraft(text: String, to targets: [SyncTarget]) async -> Bool {
        guard !targets.isEmpty else { return true }

        let payload = DraftPayload(text: text, callbackPort: callbackPort)

        return await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for target in targets {
                guard let url = targetURL(path: "/draft", target: target) else { continue }

                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 2
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONEncoder().encode(payload)

                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let httpResponse = response as? HTTPURLResponse,
                           !(200...299).contains(httpResponse.statusCode) {
                            print("AutoPaste sync failed for \(target.host):\(target.port) with status: \(httpResponse.statusCode)")
                            return false
                        }
                        return true
                    } catch {
                        print("AutoPaste sync failed for \(target.host):\(target.port): \(error.localizedDescription)")
                        return false
                    }
                }
            }

            var allSucceeded = true
            for await didSucceed in group {
                if !didSucceed {
                    allSucceeded = false
                }
            }
            return allSucceeded
        }
    }

    private func targetURL(path: String, target: SyncTarget) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = target.host
        components.port = target.port
        components.path = path
        return components.url
    }

    private var activeSyncTargets: [SyncTarget] {
        WorkflowManager.shared.autoPasteSyncWorkflows.compactMap { workflow in
            guard workflow.isActive else { return nil }
            let host = workflow.syncConfig.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return nil }
            return SyncTarget(host: host, port: workflow.syncConfig.port)
        }
    }
}

nonisolated private struct SyncTarget: Hashable, Sendable {
    let host: String
    let port: Int
}

nonisolated private struct DraftSyncState: Equatable, Sendable {
    let text: String
    let targets: Set<SyncTarget>
}

nonisolated private struct DraftPayload: Encodable, Sendable {
    let text: String
    let callbackPort: UInt16
}

private final class VibetakingControlServer {
    var onClearDraft: (() -> Void)?

    private let queue = DispatchQueue(label: "cn.1pointech.vibetaking.controlserver")
    private var listener: NWListener?

    func start(port: UInt16) {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    print("Vibetaking control server failed: \(error.localizedDescription)")
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            print("Failed to start Vibetaking control server: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            let response = self?.response(for: data, error: error) ?? Self.httpResponse(status: 500, body: "{\"error\":\"internal error\"}")
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for data: Data?, error: NWError?) -> String {
        if let error {
            return Self.httpResponse(status: 500, body: "{\"error\":\"\(error)\"}")
        }

        guard let data, let rawRequest = String(data: data, encoding: .utf8) else {
            return Self.httpResponse(status: 400, body: "{\"error\":\"invalid request\"}")
        }

        let lines = rawRequest.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return Self.httpResponse(status: 400, body: "{\"error\":\"malformed request\"}")
        }

        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 2 else {
            return Self.httpResponse(status: 400, body: "{\"error\":\"malformed request\"}")
        }

        let method = components[0].uppercased()
        let path = components[1]

        guard method == "POST" else {
            return Self.httpResponse(status: 405, body: "{\"error\":\"method not allowed\"}")
        }

        guard path == "/draft/clear" else {
            return Self.httpResponse(status: 404, body: "{\"error\":\"not found\"}")
        }

        Task { @MainActor [weak self] in
            self?.onClearDraft?()
        }
        return Self.httpResponse(status: 200, body: "{\"ok\":true}")
    }

    private static func httpResponse(status: Int, body: String) -> String {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Error"
        }

        return "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }
}
