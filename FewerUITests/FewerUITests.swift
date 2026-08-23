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
        let statusItem = app.statusItems["Fewer 工具箱"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        XCTAssertTrue(app.staticTexts["日历"].waitForExistence(timeout: 2))

        XCTAssertTrue(app.buttons["popover.settings"].exists)
        ["calendar", "screenshot", "input", "cpu", "gpu", "memory", "disk", "network", "finder", "system"].forEach { moduleID in
            XCTAssertTrue(app.buttons["toolbox.tab.\(moduleID)"].exists, "缺少工具箱标签：\(moduleID)")
        }

        app.buttons["toolbox.tab.cpu"].click()
        XCTAssertTrue(app.staticTexts["CPU"].waitForExistence(timeout: 2))

        app.buttons["toolbox.tab.screenshot"].click()
        XCTAssertTrue(app.buttons["智能截图"].waitForExistence(timeout: 2))

        app.buttons["toolbox.tab.system"].click()
        XCTAssertTrue(app.staticTexts["防休眠"].waitForExistence(timeout: 2))

        app.buttons["toolbox.tab.calendar"].click()
        XCTAssertTrue(app.staticTexts["日历"].waitForExistence(timeout: 2))
    }
}
