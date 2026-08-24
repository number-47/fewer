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
        let inputEnhancement = app.buttons["输入增强"].firstMatch
        XCTAssertTrue(inputEnhancement.waitForExistence(timeout: 5))
        inputEnhancement.click()

        let hasScroll = app.radioButtons["滚动"].waitForExistence(timeout: 2)
        let hasApplications = app.radioButtons["应用规则"].exists
        let hasGestures = app.radioButtons["鼠标手势"].exists
        let hasKeycast = app.radioButtons["按键展示"].exists
        let hasDiagnostics = app.radioButtons["诊断"].exists
        XCTAssertTrue(hasScroll)
        XCTAssertTrue(hasApplications)
        XCTAssertTrue(hasGestures)
        XCTAssertTrue(hasKeycast)
        XCTAssertTrue(hasDiagnostics)

        app.radioButtons["诊断"].click()
        XCTAssertTrue(app.staticTexts["辅助功能权限"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testModuleSettingsExposeBuiltInModules() {
        continueAfterFailure = false
        let app = launchApp()
        let modules = app.buttons["模块"].firstMatch
        XCTAssertTrue(modules.waitForExistence(timeout: 5))
        modules.click()

        XCTAssertTrue(app.staticTexts["菜单栏顺序"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["CPU"].firstMatch.exists)
        ["GPU", "内存", "磁盘", "网络", "日历"].forEach { title in
            XCTAssertTrue(app.staticTexts[title].exists, "缺少内置模块：\(title)")
        }
    }

    @MainActor
    func testMenuBarToolboxNavigation() {
        continueAfterFailure = false
        let app = launchApp()
        let statusItem = app.statusItems["Fewer 工具箱"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        XCTAssertTrue(app.buttons["toolbox.tab.calendar"].waitForExistence(timeout: 2))

        XCTAssertTrue(app.buttons["popover.settings"].exists)
        XCTAssertTrue(app.buttons["popover.quit"].exists)

        let primaryTabs = app.buttons.allElementsBoundByIndex.filter {
            $0.identifier.hasPrefix("toolbox.tab.")
        }
        XCTAssertEqual(primaryTabs.count, 3, "工具箱只能有三个一级入口")
        ["calendar", "monitor", "system"].forEach { dest in
            XCTAssertTrue(app.buttons["toolbox.tab.\(dest)"].exists, "缺少一级入口：\(dest)")
        }

        ["screenshot", "input", "finder"].forEach { destination in
            XCTAssertFalse(app.buttons["toolbox.tab.\(destination)"].exists, "不应保留一级入口：\(destination)")
        }

        let monitorTab = app.buttons["toolbox.tab.monitor"]
        monitorTab.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        XCTAssertTrue(app.buttons["toolbox.monitor.cpu"].waitForExistence(timeout: 2))
        ["gpu", "memory", "disk", "network"].forEach { moduleID in
            XCTAssertTrue(app.buttons["toolbox.monitor.\(moduleID)"].exists, "缺少监控二级入口：\(moduleID)")
        }

        app.buttons["toolbox.monitor.gpu"].click()
        XCTAssertTrue(app.buttons["toolbox.monitor.gpu"].isSelected)

        app.buttons["toolbox.tab.system"].click()
        XCTAssertTrue(app.staticTexts["防休眠"].waitForExistence(timeout: 2))

        statusItem.click()
        XCTAssertTrue(app.buttons["toolbox.tab.system"].waitForNonExistence(timeout: 2))
        statusItem.click()
        XCTAssertTrue(app.buttons["toolbox.tab.calendar"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["toolbox.tab.calendar"].isSelected)
    }

    @MainActor
    func testToolboxHeaderExposesSettingsAndQuit() {
        continueAfterFailure = false
        let app = launchApp()
        let statusItem = app.statusItems["Fewer 工具箱"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["popover.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["popover.quit"].exists)
        settings.click()
        XCTAssertTrue(app.windows["settings-window"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testPermissionsSettingsPageNavigation() {
        continueAfterFailure = false
        let app = launchApp()

        let permissions = app.buttons["权限与扩展"].firstMatch
        XCTAssertTrue(permissions.waitForExistence(timeout: 5))
        permissions.click()

        XCTAssertTrue(app.buttons["重新检测全部"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testOverviewJumpToPermissions() {
        continueAfterFailure = false
        let app = launchApp()

        let overview = app.buttons["概览"].firstMatch
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        overview.click()

        let jumpButton = app.buttons["前往"].firstMatch
        XCTAssertTrue(jumpButton.waitForExistence(timeout: 3))
        jumpButton.click()

        XCTAssertTrue(app.staticTexts["Fewer 主应用"].waitForExistence(timeout: 3))
    }
}
