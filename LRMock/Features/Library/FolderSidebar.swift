//
//  FolderSidebar.swift
//  RawLight
//
//  Left column: "All Photos", filesystem Folders and user Collections. Pure
//  presentation + selection; creation/import actions live in `RootView`'s
//  toolbar and are passed in as closures.
//

import SwiftUI
import SwiftData

struct FolderSidebar: View {
    @Query(sort: \LibraryFolder.sortIndex) private var folders: [LibraryFolder]
    @Query(sort: \AssetCollection.sortIndex) private var collections: [AssetCollection]
    @Query private var allAssets: [ImageAsset]

    @Binding var selection: LibrarySelection?

    var onNewCollection: () -> Void

    var body: some View {
        List(selection: $selection) {
            Section {
                row(
                    title: "All Photos",
                    systemImage: "photo.on.rectangle.angled",
                    count: allAssets.count
                )
                .tag(LibrarySelection.allPhotos)
            }

            Section("Folders") {
                if folders.isEmpty {
                    emptyHint("Import files to create folders")
                }
                ForEach(folders) { folder in
                    row(
                        title: folder.name,
                        systemImage: folder.kind == .external ? "folder.badge.gearshape" : "folder",
                        count: folder.assets.count
                    )
                    .tag(LibrarySelection.folder(folder.persistentModelID))
                }
            }

            Section("Collections") {
                if collections.isEmpty {
                    emptyHint("No collections yet")
                }
                ForEach(collections) { collection in
                    row(
                        title: collection.name,
                        systemImage: collection.symbol,
                        count: collection.assets.count
                    )
                    .tag(LibrarySelection.collection(collection.persistentModelID))
                }
                Button(action: onNewCollection) {
                    Label("New Collection", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("new-collection-button")
                .foregroundStyle(Theme.accent)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("RawLight")
        .accessibilityIdentifier("library-sidebar")
        .tint(Theme.accent)
    }

    // MARK: Rows

    private func row(title: String, systemImage: String, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(Theme.textTertiary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Theme.accent)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
    }
}
