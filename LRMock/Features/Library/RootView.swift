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
    @Environment(AppServices.self) private var services

    // Catalog queries used to resolve the current selection.
    @Query(sort: \LibraryFolder.sortIndex) private var folders: [LibraryFolder]
    @Query(sort: \AssetCollection.sortIndex) private var collections: [AssetCollection]
    @Query private var allAssets: [ImageAsset]

    // UI state.
    @State private var selection: LibrarySelection? = .allPhotos
    @State private var selectedAsset: ImageAsset?
    @State private var isLoupeOpen = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    // Import sheets.
    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var importMessage: String?

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
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .rawImage],
            allowsMultipleSelection: true
        ) { handleFileImport($0) }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { handleFolderImport($0) }
        .overlay(alignment: .bottom) { importToast }
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
                Picker("Engine", selection: Binding(
                    get: { services.engine },
                    set: { services.engine = $0 }
                )) {
                    ForEach(PipelineKind.allCases) { kind in
                        Text(kind.label)
                            .tag(kind)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Engine", systemImage: "cpu")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import Files…", systemImage: "doc.badge.plus")
                }
                Button {
                    showFolderImporter = true
                } label: {
                    Label("Import Folder…", systemImage: "folder.badge.plus")
                }
                Button {
                    scanManagedFolder()
                } label: {
                    Label("Scan RawLight Folder", systemImage: "arrow.clockwise")
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
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
        withAnimation(.easeInOut(duration: 0.2)) { isLoupeOpen = true }
    }

    private func closeLoupe() {
        // Persist edits to the portable sidecar when leaving the editor.
        if let asset = selectedAsset { persistSidecar(for: asset) }
        withAnimation(.easeInOut(duration: 0.2)) { isLoupeOpen = false }
    }

    // MARK: Import handlers

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let summary = ImportService(modelContext: modelContext)
            .importFiles(urls, into: selectedFolder, copyIntoLibrary: false)
        show(summary)
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let folderURL = urls.first else { return }

        // Create a sidebar folder that references the external directory.
        let folder = LibraryFolder(
            name: folderURL.lastPathComponent,
            kind: .external,
            sortIndex: folders.count
        )
        folder.bookmarkData = try? BookmarkStore.makeBookmark(for: folderURL)
        modelContext.insert(folder)

        let summary = ImportService(modelContext: modelContext)
            .importFolder(folderURL, into: folder)
        selection = .folder(folder.persistentModelID)
        show(summary)
    }

    private func scanManagedFolder() {
        let summary = ImportService(modelContext: modelContext).scanManagedLibrary(into: nil)
        show(summary)
    }

    // MARK: Actions

    private func createCollection() {
        let collection = AssetCollection(name: "New Collection", sortIndex: collections.count)
        modelContext.insert(collection)
        try? modelContext.save()
    }

    private func persistSidecar(for asset: ImageAsset) {
        try? AssetFileAccess.withAccess(asset) { url in
            try SidecarService.write(SidecarService.snapshot(of: asset), for: url)
        }
    }

    private func show(_ summary: ImportService.Summary) {
        let text = "Imported \(summary.imported)"
            + (summary.skipped > 0 ? " · skipped \(summary.skipped)" : "")
            + (summary.failed > 0 ? " · failed \(summary.failed)" : "")
        withAnimation { importMessage = text }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { importMessage = nil }
        }
    }
}

#Preview {
    RootView()
        .modelContainer(CatalogStore.makeInMemoryContainer())
        .preferredColorScheme(.dark)
}
