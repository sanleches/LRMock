//
//  LRMockUITests.swift
//  LRMockUITests
//
//  Created by sugartesalas on 2026-10-08.
//

import XCTest

final class LRMockUITests: XCTestCase {

    private var app: XCUIApplication!
    private var libraryRoot: URL!
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-UITests-\(UUID().uuidString)", isDirectory: true)
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-UICache-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["RAWLIGHT_LIBRARY_ROOT"] = libraryRoot.path
        app.launchEnvironment["RAWLIGHT_CACHE_ROOT"] = cacheRoot.path
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let libraryRoot { try? FileManager.default.removeItem(at: libraryRoot) }
        if let cacheRoot { try? FileManager.default.removeItem(at: cacheRoot) }
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
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let pointer = """
        { "schemaVersion": 999, "generationID": "\(UUID().uuidString)" }
        """
        try Data(pointer.utf8).write(
            to: libraryRoot.appendingPathComponent("CurrentLibrary.json")
        )

        app.launch()
        XCTAssertTrue(app.staticTexts["Library Could Not Be Opened"].waitForExistence(timeout: 5))
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
