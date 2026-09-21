import UIKit
import XCTest

@MainActor
final class DraftEditorLayoutUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "cn.1pointech.vibetaking")
    private var clipboardItems: [[String: Any]] = []

    private var editor: XCUIElement { app.textViews["draft-editor"] }
    private var title: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "随心记").firstMatch
    }
    private var modeButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["草稿标签", "退出专注"])).firstMatch
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        clipboardItems = UIPasteboard.general.items
        // Launch overrides select local demo storage without changing the user's mode preference.
        app.launchArguments = ["-demoModeEnabled", "YES"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        if app.buttons["退出专注"].exists {
            app.buttons["退出专注"].tap()
        }
        clearDraft()
    }

    override func tearDownWithError() throws {
        app.terminate()
        UIPasteboard.general.items = clipboardItems
    }

    func testLongPasteKeepsPageBounds() {
        checkLongPastes()
    }

    func testLongPasteInFocusModeKeepsPageBounds() {
        app.navigationBars.buttons["更多操作"].tap()
        app.buttons["进入专注模式"].tap()
        let workflow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "focus-workflow-")).firstMatch
        XCTAssertTrue(workflow.waitForExistence(timeout: 5))
        workflow.tap()
        XCTAssertTrue(app.buttons["退出专注"].waitForExistence(timeout: 5))
        checkLongPastes()
    }

    func testPasteIntoExistingDraft() {
        editor.typeText("已有草稿。")
        let toolbarY = assertPageBounds()
        // A blank area below this short first line places the insertion point at its end.
        paste(Self.multilineText)
        assertText("已有草稿。" + Self.multilineText)
        assertPageBounds(toolbarY: toolbarY)
        capture("paste-into-existing-draft")
    }

    func testClearRestoreAndReopenLongDraft() {
        paste(Self.multilineText)
        assertText(Self.multilineText)
        clearDraft()
        app.buttons["恢复草稿"].tap()
        assertText(Self.multilineText)
        assertPageBounds()

        // Backgrounding flushes the debounced draft write before terminating the process.
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        assertText(Self.multilineText)
        assertPageBounds()
        capture("reopened-long-draft")
    }

    func testLongPasteWithAccessibilityTextSize() {
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let toolbarY = assertPageBounds()
        paste(Self.multilineText)
        assertText(Self.multilineText)
        assertPageBounds(toolbarY: toolbarY)
        capture("long-paste-accessibility-text-size")
    }

    private func checkLongPastes() {
        for (name, text) in Self.documents {
            clearDraft()
            let toolbarY = assertPageBounds()
            paste(text)
            assertText(text)
            assertPageBounds(toolbarY: toolbarY)
            capture("\(name)-pasted")

            for _ in 0..<4 { editor.swipeDown(velocity: .fast) }
            assertPageBounds(toolbarY: toolbarY)
            capture("\(name)-top")
            for _ in 0..<4 { editor.swipeUp(velocity: .fast) }
            assertPageBounds(toolbarY: toolbarY)
            assertText(text)
            capture("\(name)-bottom")
        }
    }

    private func paste(_ text: String) {
        UIPasteboard.general.string = text
        editor.press(forDuration: 1.1)
        let pasteButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["粘贴", "Paste"])).firstMatch
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 5), app.debugDescription)
        pasteButton.tap()
    }

    private func clearDraft() {
        if app.buttons["清除草稿"].exists {
            app.buttons["清除草稿"].tap()
            assertText("")
        }
        let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已")).firstMatch
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !status.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 7), .completed)
    }

    private func assertText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            editor.value as? String == text
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed, file: file, line: line)
    }

    @discardableResult
    private func assertPageBounds(toolbarY: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) -> CGFloat {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            modeButton.exists && modeButton.isHittable
                && (toolbarY.map { abs(modeButton.frame.midY - $0) < 2 } ?? true)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed, file: file, line: line)

        let window = app.windows.firstMatch.frame
        let frame = editor.frame
        let navigation = app.navigationBars.firstMatch.frame
        XCTAssertFalse(frame.isEmpty, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX + 15, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX - 15, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, navigation.maxY, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, modeButton.frame.minY + 1, file: file, line: line)
        XCTAssertTrue(title.exists && !title.frame.isEmpty && window.contains(title.frame), file: file, line: line)
        XCTAssertGreaterThan(title.frame.height, 0, file: file, line: line)
        XCTAssertTrue(app.navigationBars.buttons["记录"].isHittable, file: file, line: line)

        let clear = app.buttons.matching(NSPredicate(format: "label IN %@", ["清除草稿", "恢复草稿", "清除标签", "恢复标签"])).firstMatch
        XCTAssertTrue(clear.exists && window.contains(clear.frame), file: file, line: line)
        if clear.isEnabled {
            XCTAssertTrue(clear.isHittable, file: file, line: line)
        }
        XCTAssertEqual(clear.frame.midY, modeButton.frame.midY, accuracy: 2, file: file, line: line)
        return modeButton.frame.midY
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static let multilineText = (1...45).map {
        "第\($0)行：项目目标、当前状态、关键决策、待办、风险和下一步。"
    }.joined(separator: "\n") + "\n文档结束。"

    private static let documents: [(String, String)] = [
        ("multiline", multilineText),
        ("mixed-code", String(repeating: "项目进展\nfunc search(query: String) -> [String] {\n    return [query]\n}\n运行测试并记录结果。\n", count: 12) + "文档结束。"),
        ("unbroken-line", String(repeating: "abcdefghijklmnopqrstuvwxyz0123456789", count: 100) + "文档结束。")
    ]
}
