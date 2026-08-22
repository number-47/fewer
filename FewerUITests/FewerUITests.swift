import XCTest

final class FewerUITests: XCTestCase {
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    func testInputEnhancementSettingsNavigation() {
        continueAfterFailure = false
        let app = launchApp()
        let inputEnhancement = app.staticTexts["输入增强"].firstMatch
        XCTAssertTrue(inputEnhancement.waitForExistence(timeout: 5))
        inputEnhancement.click()

        let hasScroll = app.buttons["滚动"].waitForExistence(timeout: 2)
        let hasApplications = app.buttons["应用规则"].exists
        let hasGestures = app.buttons["鼠标手势"].exists
        let hasKeycast = app.buttons["按键展示"].exists
        let hasDiagnostics = app.buttons["诊断"].exists
        XCTAssertTrue(hasScroll)
        XCTAssertTrue(hasApplications)
        XCTAssertTrue(hasGestures)
        XCTAssertTrue(hasKeycast)
        XCTAssertTrue(hasDiagnostics)

        app.buttons["诊断"].click()
        XCTAssertTrue(app.staticTexts["辅助功能权限"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testModuleSettingsExposeBuiltInModules() {
        continueAfterFailure = false
        let app = launchApp()
        let modules = app.staticTexts["模块"].firstMatch
        XCTAssertTrue(modules.waitForExistence(timeout: 5))
        modules.click()

        let hasDashboard = app.staticTexts["仪表盘"].waitForExistence(timeout: 2)
        let hasCalendar = app.staticTexts["日历"].exists
        let hasScreenshot = app.staticTexts["截图"].exists
        let hasSystem = app.staticTexts["系统快捷操作"].exists
        XCTAssertTrue(hasDashboard)
        XCTAssertTrue(hasCalendar)
        XCTAssertTrue(hasScreenshot)
        XCTAssertTrue(hasSystem)
    }

    @MainActor
    func testMenuBarCommandPanel() {
        continueAfterFailure = false
        let app = launchApp()
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        XCTAssertTrue(app.buttons["仪表盘"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["日历"].exists)
        XCTAssertTrue(app.buttons["截图"].exists)
        XCTAssertTrue(app.buttons["输入"].exists)
        XCTAssertTrue(app.buttons["Finder"].exists)
        XCTAssertTrue(app.buttons["系统"].exists)
    }
}
