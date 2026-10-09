//
//  RootView.swift
//  RawLight
//
//  Top-level screen: NavigationSplitView(sidebar, detail). Owns library
//  selection, the grid↔loupe switch, and all import entry points. Keeps the
//  child views dumb by resolving the selection into a concrete asset list here.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.modelContext) private var modelContext

    // Catalog queries used to resolve the current selection.
    @Query(sort: \LibraryFolder.sortIndex) private var folders: [LibraryFolder]
    @Query(sort: \AssetCollection.sortIndex) private var collections: [AssetCollection]
    @Query private var allAssets: [ImageAsset]

    // UI state.
    @State private var selection: LibrarySelection? = .allPhotos
    @State private var selectedAsset: ImageAsset?
    @State private var isLoupeOpen = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Import. A single `.fileImporter` driven by `importMode` — stacking two
    // fileImporters on one view conflicts (the later one wins), which on macOS
    // made "Import Photos" silently do nothing.
    enum ImportMode { case files, folder }
    @State private var importMode: ImportMode = .files
    @State private var showImporter = false
    @State private var importMessage: String?
    @State private var importMessageID = UUID()
    @State private var isImporting = false
    @State private var operationError: String?

    private var importContentTypes: [UTType] {
        importMode == .folder ? [.folder] : [.image, .rawImage]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FolderSidebar(selection: $selection, onNewCollection: createCollection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
                .toolbar { importToolbar }
        } detail: {
            detail
        }
        .tint(Theme.accent)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importContentTypes,
            allowsMultipleSelection: importMode != .folder
        ) { result in
            switch importMode {
            case .files:  handleFileImport(result)
            case .folder: handleFolderImport(result)
            }
        }
        .overlay(alignment: .bottom) { importToast }
        .alert("Operation Failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "Unknown error")
        }
        // Picking a folder/collection in the sidebar always returns to its grid,
        // even from the full-screen editor.
        .onChange(of: selection) { _, _ in
            if let selectedAsset { persistSidecar(for: selectedAsset) }
            selectedAsset = nil
            if isLoupeOpen {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isLoupeOpen = false
                    columnVisibility = .all
                }
            }
        }
    }

    // MARK: Detail (grid ↔ loupe)

    @ViewBuilder
    private var detail: some View {
        if isLoupeOpen {
            LoupeView(
                assets: currentAssets,
                selectedAsset: $selectedAsset,
                onClose: closeLoupe
            )
        } else {
            PhotoGridView(
                title: currentTitle,
                assets: currentAssets,
                selectedAsset: $selectedAsset,
                onOpen: openLoupe
            )
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    importMode = .files
                    showImporter = true
                } label: {
                    Label("Import Photos (copy to Library)…", systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    importMode = .folder
                    showImporter = true
                } label: {
                    Label("Reference Folder (keep in place)…", systemImage: "folder.badge.gearshape")
                }
                Divider()
                Button {
                    LibraryReveal.revealLibrary()
                } label: {
                    Label(LibraryReveal.revealTitle, systemImage: "folder")
                }
            } label: {
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
            .accessibilityIdentifier("import-menu")
            .disabled(isImporting)
        }
    }

    @ViewBuilder
    private var importToast: some View {
        if let importMessage {
            Text(importMessage)
                .font(.subheadline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.surface, in: Capsule())
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Selection resolution

    private var selectedFolder: LibraryFolder? {
        guard case .folder(let id) = selection else { return nil }
        return folders.first { $0.persistentModelID == id }
    }

    private var currentAssets: [ImageAsset] {
        let list: [ImageAsset]
        switch selection {
        case .folder(let id):
            list = folders.first { $0.persistentModelID == id }?.assets ?? []
        case .collection(let id):
            list = collections.first { $0.persistentModelID == id }?.assets ?? []
        default:
            list = allAssets
        }
        return list.sorted {
            ($0.captureDate ?? $0.importedAt) > ($1.captureDate ?? $1.importedAt)
        }
    }

    private var currentTitle: String {
        switch selection {
        case .folder(let id):
            return folders.first { $0.persistentModelID == id }?.name ?? "Folder"
        case .collection(let id):
            return collections.first { $0.persistentModelID == id }?.name ?? "Collection"
        default:
            return "All Photos"
        }
    }

    // MARK: Loupe transitions

    private func openLoupe(_ asset: ImageAsset) {
        selectedAsset = asset
        withAnimation(.easeInOut(duration: 0.25)) {
            isLoupeOpen = true
            // Collapse the folder/collection sidebar for a full-width editor.
            columnVisibility = .detailOnly
        }
    }

    private func closeLoupe() {
        // Persist edits to the portable sidecar when leaving the editor.
        if let asset = selectedAsset { persistSidecar(for: asset) }
        withAnimation(.easeInOut(duration: 0.25)) {
            isLoupeOpen = false
            // Bring the sidebar back so the user can browse folders again.
            columnVisibility = .all
        }
    }

    // MARK: Import handlers

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls) where !urls.isEmpty:
            Task {
                isImporting = true
                let summary = await ImportService(modelContext: modelContext)
                    .importFiles(urls, into: selectedFolder, copyIntoLibrary: true)
                isImporting = false
                show(summary)
            }
        case .success:
            break
        case .failure(let error):
            operationError = error.localizedDescription
        }
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            do {
                let bookmark = try BookmarkStore.makeBookmark(for: folderURL)
                let folder = LibraryFolder(
                    name: folderURL.lastPathComponent,
                    kind: .external,
                    sortIndex: folders.count
                )
                folder.bookmarkData = bookmark
                modelContext.insert(folder)
                try modelContext.save()

                Task {
                    isImporting = true
                    let summary = await ImportService(modelContext: modelContext)
                        .importFolder(folderURL, into: folder)
                    isImporting = false
                    selection = .folder(folder.persistentModelID)
                    show(summary)
                }
            } catch {
                operationError = error.localizedDescription
            }
        case .failure(let error):
            operationError = error.localizedDescription
        }
    }

    // MARK: Actions

    private func createCollection() {
        let collection = AssetCollection(name: "New Collection", sortIndex: collections.count)
        modelContext.insert(collection)
        do {
            try modelContext.save()
        } catch {
            modelContext.delete(collection)
            operationError = error.localizedDescription
        }
    }

    private func persistSidecar(for asset: ImageAsset) {
        do {
            try modelContext.save()
            try EditPersistence.writeSidecar(for: asset)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func show(_ summary: ImportService.Summary) {
        let text = "Imported \(summary.imported)"
            + (summary.skipped > 0 ? " · skipped \(summary.skipped)" : "")
            + (summary.failed > 0 ? " · failed \(summary.failed)" : "")
        if !summary.errors.isEmpty {
            operationError = summary.errors.prefix(5).joined(separator: "\n")
        }
        let messageID = UUID()
        importMessageID = messageID
        withAnimation { importMessage = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard importMessageID == messageID else { return }
            withAnimation { importMessage = nil }
        }
    }
}

#Preview {
    let container = CatalogStore.makeInMemoryContainer()
    RootView()
        .modelContainer(container)
        .environment(AppServices())
        .preferredColorScheme(.dark)
}
