//
//  CatalogRecoveryView.swift
//  RawLight
//
//  Read-only startup state shown when the persistent catalog cannot be opened.
//  The failed store is preserved verbatim for repair or migration.
//

import SwiftUI

struct CatalogRecoveryView: View {
    let failure: CatalogStore.LoadFailure

    var body: some View {
        ContentUnavailableView {
            Label("Library Could Not Be Opened", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("RawLight preserved the existing catalog and did not create or delete library data. Close the app, verify the disk is available, then try again.\n\n\(failure.message)")
                .accessibilityIdentifier("catalog-recovery-message")
        } actions: {
            #if os(macOS)
            Button("Show Library in Finder") {
                LibraryReveal.reveal(failure.libraryURL)
            }
            #endif
        }
        .padding(32)
        .frame(minWidth: 560, minHeight: 360)
    }
}
