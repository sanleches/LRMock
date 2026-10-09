//
//  LibraryReveal.swift
//  RawLight
//
//  Exposes the managed library location to the user. On macOS this reveals the
//  library generation folder in Finder (the Lightroom-style "catalog folder"
//  holding Originals/, Recipes/, and the catalog). On iPadOS the library lives
//  in the app's Application Support container.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

@MainActor
enum LibraryReveal {

    static var revealTitle: String {
        #if os(macOS)
        return "Reveal Library in Finder"
        #else
        return "Library Location"
        #endif
    }

    static func revealLibrary() {
        let url = LibraryLocations.currentGeneration
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}
