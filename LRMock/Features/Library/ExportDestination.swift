//
//  ExportDestination.swift
//  RawLight
//
//  Platform-native "save the rendered file" step. On macOS this is a real
//  `NSSavePanel` (choose folder + filename, then reveal in Finder); presenting a
//  SwiftUI `.fileExporter` on top of an existing sheet behaves poorly there, so
//  we use AppKit directly. iPadOS uses `.fileExporter` from the view.
//

import Foundation
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

@MainActor
enum ExportDestination {

    enum Result { case saved(URL), cancelled, failed }

    /// macOS only: shows a Save panel, writes `data`, and reveals the file.
    /// Uses the non-blocking `begin` API so it works from an async context.
    static func runSavePanel(data: Data, suggestedName: String, type: UTType) async -> Result {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export Photo"
        panel.prompt = "Export"
        NSApp.activate(ignoringOtherApps: true)

        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return .cancelled }
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return .saved(url)
        } catch {
            return .failed
        }
        #else
        return .cancelled
        #endif
    }
}
