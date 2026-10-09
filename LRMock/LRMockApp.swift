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

    private let catalog = CatalogStore.makeContainer()
    private let services = AppServices()

    var body: some Scene {
        WindowGroup {
            Group {
                if let failure = catalog.failure {
                    CatalogRecoveryView(failure: failure)
                } else {
                    RootView()
                }
            }
            .environment(services)
            .preferredColorScheme(.dark)
        }
        .modelContainer(catalog.container)
    }
}
