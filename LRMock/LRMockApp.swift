//
//  LRMockApp.swift
//  RawLight
//
//  Application entry point.
//
//  Responsibilities kept intentionally tiny:
//    * create the SwiftData container (schema lives in `CatalogStore`)
//    * ensure the on-disk library/cache directories exist
//    * inject shared services and show the root UI
//

import SwiftUI
import SwiftData

@main
struct LRMockApp: App {

    private let modelContainer = CatalogStore.makeContainer()
    private let services = AppServices()

    init() {
        // Create Documents/Managed and the thumbnail cache up front.
        try? LibraryLocations.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services)
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
    }
}
