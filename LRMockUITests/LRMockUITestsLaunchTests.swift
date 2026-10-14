//
//  LRMockUITestsLaunchTests.swift
//  LRMockUITests
//
//  Created by sugartesalas on 2026-10-08.
//

import XCTest

final class LRMockUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RAWLIGHT_UI_TEST_ROOT_ID"] = UUID().uuidString
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        defer {
            app.terminate()
        }
        app.launch()

        XCTAssertTrue(app.staticTexts["All Photos"].waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
