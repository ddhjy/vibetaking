import XCTest

@MainActor
final class NavigationToolbarUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "cn.1pointech.vibetaking")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.textViews["draft-editor"].waitForExistence(timeout: 10))
    }

    func testToolbarReturnsFromAssistant() {
        let initialFrame = homeToolbarFrame()
        capture("home-before-navigation")

        for visit in 1...3 {
            openAssistant()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            assertToolbarVisible(expectedFrame: initialFrame)
            capture("home-after-assistant-\(visit)")
        }
    }

    func testToolbarReturnsFromAssistantWithKeyboard() {
        let initialFrame = homeToolbarFrame()
        openAssistant()
        app.descendants(matching: .any).matching(identifier: "发给 AI 助手的消息").firstMatch.tap()
        capture("assistant-with-keyboard")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        assertToolbarVisible(expectedFrame: initialFrame)
        capture("home-after-assistant-keyboard")
    }

    func testToolbarReturnsFromAssistantWithSwipe() {
        let initialFrame = homeToolbarFrame()
        openAssistant()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        assertToolbarVisible(expectedFrame: initialFrame)
        capture("home-after-assistant-swipe")
    }

    func testToolbarReturnsFromHistory() {
        let initialFrame = homeToolbarFrame()
        app.navigationBars.buttons["记录"].tap()
        XCTAssertTrue(app.navigationBars["记录"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textViews["draft-editor"].waitForExistence(timeout: 5))
        assertToolbarVisible(expectedFrame: initialFrame)
        capture("home-after-history")
    }

    private var tagButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", ["草稿标签", "退出专注"])).firstMatch
    }

    private func homeToolbarFrame() -> CGRect {
        app.textViews["draft-editor"].tap()
        assertToolbarVisible()
        return tagButton.frame
    }

    private func openAssistant() {
        app.navigationBars.buttons["更多操作"].tap()
        app.buttons["AI 助手"].tap()
        XCTAssertTrue(app.navigationBars["AI 助手"].waitForExistence(timeout: 5))
    }

    private func assertToolbarVisible(expectedFrame: CGRect? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let tags = tagButton
        let visible = NSPredicate { _, _ in
            tags.exists && tags.isHittable && !tags.frame.isEmpty
                && (expectedFrame.map { abs(tags.frame.minY - $0.minY) < 2 } ?? true)
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "Toolbar: \(tags.frame), expected: \(String(describing: expectedFrame))", file: file, line: line)
        let workflows = app.buttons["工作流设置"]
        if workflows.exists {
            XCTAssertTrue(workflows.isHittable, file: file, line: line)
            XCTAssertEqual(workflows.frame.midY, tags.frame.midY, accuracy: 2, file: file, line: line)
        }
        let clear = app.buttons.matching(NSPredicate(format: "label IN %@", ["清除草稿", "恢复草稿", "清除标签", "恢复标签"])).firstMatch
        XCTAssertTrue(clear.exists, file: file, line: line)
        XCTAssertEqual(clear.frame.midY, tags.frame.midY, accuracy: 2, file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
