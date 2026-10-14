//
//  LRMockUITests.swift
//  LRMockUITests
//
//  Created by sugartesalas on 2026-10-08.
//

import XCTest

final class LRMockUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["RAWLIGHT_UI_TEST_ROOT_ID"] = UUID().uuidString
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    @MainActor
    func testEmptyLibraryAndCollectionCreation() throws {
        app.launch()

        XCTAssertTrue(app.staticTexts["All Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No photos here yet"].exists)
        XCTAssertTrue(app.menuButtons["import-menu"].exists)

        let addCollection = app.buttons["new-collection-button"]
        XCTAssertTrue(addCollection.exists)
        addCollection.click()
        XCTAssertTrue(app.staticTexts["New Collection"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testUnsupportedLibraryPointerShowsRecovery() throws {
        app.launchEnvironment["RAWLIGHT_UI_TEST_POINTER_SCHEMA_VERSION"] = "999"

        app.launch()
        XCTAssertTrue(app.staticTexts["Library Could Not Be Opened"].waitForExistence(timeout: 5))
        let message = app.staticTexts["catalog-recovery-message"]
        XCTAssertTrue(message.exists)
        XCTAssertTrue((message.value as? String)?.contains("unsupported version 999") == true)
        XCTAssertTrue(app.buttons["Show Library in Finder"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }
}
