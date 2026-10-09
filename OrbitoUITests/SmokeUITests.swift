import XCTest

final class SmokeUITests: XCTestCase {
    @MainActor
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-OrbitoSection", "dashboard"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Запланированные задачи"].waitForExistence(timeout: 15))
    }
}
