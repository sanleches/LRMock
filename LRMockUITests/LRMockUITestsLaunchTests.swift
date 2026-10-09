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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-LaunchTests-\(UUID().uuidString)", isDirectory: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-LaunchCache-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment["RAWLIGHT_LIBRARY_ROOT"] = root.path
        app.launchEnvironment["RAWLIGHT_CACHE_ROOT"] = cache.path
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache)
        }
        app.launch()

        XCTAssertTrue(app.staticTexts["All Photos"].waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
