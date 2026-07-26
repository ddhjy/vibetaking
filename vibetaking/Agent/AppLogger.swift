// Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis) — Shared/AppLogger.swift
// Copyright (C) OpenMinis contributors. Licensed under GPL-3.0; see LICENSE.
// Modifications for vibetaking: removed CrashReporter log mirroring.

import Foundation

nonisolated struct AppLogger: Sendable {
    let category: String

    init(subsystem: String = "cn.1pointech.vibetaking", category: String) {
        self.category = category
    }

    /// DEBUG is suppressed in Release builds. `@autoclosure` so the message
    /// string isn't even built in Release.
    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        log("DEBUG", message())
        #endif
    }
    func info(_ message: String)     { log("INFO", message) }
    func notice(_ message: String)   { log("NOTICE", message) }
    func warning(_ message: String)  { log("WARN", message) }
    func error(_ message: String)    { log("ERROR", message) }
    func critical(_ message: String) { log("CRIT", message) }
    func fault(_ message: String)    { log("FAULT", message) }

    private func log(_ level: String, _ message: String) {
        NSLog("[%@] [%@] %@", category, level, message)
    }
}
