import Foundation

enum AppDefaults {
    static let suite = "vibetaking-hig-check-" + UUID().uuidString
    static let current = UserDefaults(suiteName: suite)!
}
struct AppLogger {
    init(category: String) {}
    func info(_ message: String) {}
}

@main struct PermissionChecks {
    @MainActor static func pending(_ manager: OffloadPermissionManager) async throws -> PermissionRequest {
        for _ in 0..<200 {
            if let request = manager.pendingRequest { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Permission sheet did not appear")
    }

    @MainActor static func main() async throws {
        defer { AppDefaults.current.removePersistentDomain(forName: AppDefaults.suite) }
        let manager = OffloadPermissionManager.shared
        let allow = Task { await manager.checkPermission(for: "apple-calendar", sessionId: "allow") }
        let request = try await pending(manager)
        manager.respond(to: request.id, allowed: true)
        guard case .allowed = await allow.value else { fatalError("Allow failed") }
        guard case .allowed = await manager.checkPermission(for: "apple-calendar", sessionId: "allow") else { fatalError("Session grant failed") }
        precondition(manager.pendingRequest == nil)
        print("PASS: allow and reuse only within the same session")

        let reject = Task { await manager.checkPermission(for: "apple-calendar", sessionId: "reject") }
        let rejection = try await pending(manager)
        manager.respond(to: rejection.id, allowed: false)
        guard case .denied = await reject.value else { fatalError("Deny failed") }
        print("PASS: reject does not grant access")

        let cancelled = Task { await manager.checkPermission(for: "apple-reminders", sessionId: "cancel") }
        _ = try await pending(manager)
        cancelled.cancel()
        guard case .denied = await cancelled.value else { fatalError("Cancellation did not deny") }
        precondition(manager.pendingRequest == nil)
        print("PASS: cancellation resolves the waiting task and closes the sheet")

        let immediate = Task { await manager.checkPermission(for: "apple-reminders", sessionId: "immediate") }
        immediate.cancel()
        guard case .denied = await immediate.value else { fatalError("Immediate cancellation did not deny") }
        precondition(manager.pendingRequest == nil)
        print("PASS: cancellation before presentation does not leave a pending sheet")

        let first = Task { await manager.checkPermission(for: "apple-calendar", sessionId: "queue") }
        let firstRequest = try await pending(manager)
        let second = Task { await manager.checkPermission(for: "apple-reminders", sessionId: "queue") }
        try await Task.sleep(for: .milliseconds(30))
        precondition(manager.pendingRequest?.id == firstRequest.id, "New request replaced a visible sheet")
        manager.respond(to: firstRequest.id, allowed: true)
        let secondRequest = try await pending(manager)
        precondition(secondRequest.commandName == "apple-reminders")
        manager.respond(to: secondRequest.id, allowed: false)
        guard case .allowed = await first.value, case .denied = await second.value else { fatalError("Queue responses were mixed") }
        print("PASS: concurrent permissions are presented in order and both tasks resolve")

        let duplicateA = Task { await manager.checkPermission(for: "apple-clipboard", sessionId: "duplicates") }
        let duplicateRequest = try await pending(manager)
        let duplicateB = Task { await manager.checkPermission(for: "apple-clipboard", sessionId: "duplicates") }
        try await Task.sleep(for: .milliseconds(30))
        manager.respond(to: duplicateRequest.id, allowed: true)
        guard case .allowed = await duplicateA.value, case .allowed = await duplicateB.value else { fatalError("Same-session duplicate failed") }
        precondition(manager.pendingRequest == nil)
        print("PASS: queued duplicate permission reuses the same-session grant")

        let visible = Task { await manager.checkPermission(for: "apple-calendar", sessionId: "queue-cancel") }
        let visibleRequest = try await pending(manager)
        let queued = Task { await manager.checkPermission(for: "apple-reminders", sessionId: "queue-cancel") }
        try await Task.sleep(for: .milliseconds(30))
        queued.cancel()
        guard case .denied = await queued.value else { fatalError("Queued cancellation failed") }
        precondition(manager.pendingRequest?.id == visibleRequest.id)
        visible.cancel()
        guard case .denied = await visible.value else { fatalError("Visible cancellation failed") }
        precondition(manager.pendingRequest == nil)
        print("PASS: cancelling a queued request preserves the visible request")

        let arguments = Task { await manager.checkPermission(for: "apple-reminders", sessionId: "arguments", fullCommand: "apple-reminders create --title \"Read a book\" --due -7d --flag") }
        let argumentRequest = try await pending(manager)
        precondition(argumentRequest.parsedArguments.contains { $0.key == "title" && $0.value == "Read a book" })
        precondition(argumentRequest.parsedArguments.contains { $0.key == "due" && $0.value == "-7d" })
        manager.respond(to: argumentRequest.id, allowed: false)
        _ = await arguments.value
        print("PASS: permission details preserve quoted text and negative relative dates")

        let reading = Task { await manager.checkPermission(for: "apple-clipboard", sessionId: "reading") }
        let readingRequest = try await pending(manager)
        try await Task.sleep(for: .seconds(31))
        precondition(manager.pendingRequest?.id == readingRequest.id, "Sheet disappeared while reading")
        manager.respond(to: readingRequest.id, allowed: false)
        guard case .denied = await reading.value else { fatalError("Reading response failed") }
        print("PASS: reading time is not limited to 30 seconds; explicit rejection still resolves")
    }
}
