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

    var onCreateFolder: (String) -> Void
    var onCreateCollection: (String) -> Void
    var onRenameFolder: (LibraryFolder, String) -> Void
    var onRenameCollection: (AssetCollection, String) -> Void
    var onDeleteFolder: (LibraryFolder) -> Void
    var onDeleteCollection: (AssetCollection) -> Void
    var onSelectionActivated: (LibrarySelection) -> Void

    @State private var namingTarget: NamingTarget?
    @State private var nameDraft = ""
    @State private var deletionTarget: DeletionTarget?

    private enum NamingTarget {
        case newFolder
        case newCollection
        case folder(LibraryFolder)
        case collection(AssetCollection)
    }

    private enum DeletionTarget {
        case folder(LibraryFolder)
        case collection(AssetCollection)
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                row(
                    title: "All Photos",
                    systemImage: "photo.on.rectangle.angled",
                    count: allAssets.count
                )
                .tag(LibrarySelection.allPhotos)
                .simultaneousGesture(TapGesture().onEnded {
                    onSelectionActivated(.allPhotos)
                })
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
                    .simultaneousGesture(TapGesture().onEnded {
                        onSelectionActivated(.folder(folder.persistentModelID))
                    })
                    .contextMenu {
                        Button("Rename Folder…") { beginRenaming(folder) }
                        Divider()
                        Button("Delete Folder", role: .destructive) {
                            deletionTarget = .folder(folder)
                        }
                    }
                }
                Button {
                    beginCreatingFolder()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("new-folder-button")
                .foregroundStyle(Theme.accent)
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
                    .simultaneousGesture(TapGesture().onEnded {
                        onSelectionActivated(.collection(collection.persistentModelID))
                    })
                    .contextMenu {
                        Button("Rename Collection…") { beginRenaming(collection) }
                        Divider()
                        Button("Delete Collection", role: .destructive) {
                            deletionTarget = .collection(collection)
                        }
                    }
                }
                Button {
                    beginCreatingCollection()
                } label: {
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
        .alert(namingTitle, isPresented: namingPresented) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) { namingTarget = nil }
            Button(namingActionTitle) { commitName() }
                .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(namingMessage)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionPresented,
            titleVisibility: .visible
        ) {
            Button(deletionActionTitle, role: .destructive) { commitDeletion() }
            Button("Cancel", role: .cancel) { deletionTarget = nil }
        } message: {
            Text(deletionMessage)
        }
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

    // MARK: Folder and collection management

    private var namingPresented: Binding<Bool> {
        Binding(
            get: { namingTarget != nil },
            set: { if !$0 { namingTarget = nil } }
        )
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { deletionTarget != nil },
            set: { if !$0 { deletionTarget = nil } }
        )
    }

    private var namingTitle: String {
        switch namingTarget {
        case .newFolder: "New Folder"
        case .newCollection: "New Collection"
        case .folder: "Rename Folder"
        case .collection: "Rename Collection"
        case nil: "Name"
        }
    }

    private var namingActionTitle: String {
        switch namingTarget {
        case .newFolder, .newCollection: "Create"
        case .folder, .collection: "Rename"
        case nil: "Save"
        }
    }

    private var namingMessage: String {
        switch namingTarget {
        case .newFolder:
            "Folders organize photos in the catalog without moving original files."
        case .newCollection:
            "A photo can belong to more than one collection."
        case .folder, .collection:
            "This changes the catalog name only."
        case nil:
            ""
        }
    }

    private var deletionTitle: String {
        switch deletionTarget {
        case .folder: "Delete Folder?"
        case .collection: "Delete Collection?"
        case nil: "Delete?"
        }
    }

    private var deletionActionTitle: String {
        switch deletionTarget {
        case .folder: "Delete Folder"
        case .collection: "Delete Collection"
        case nil: "Delete"
        }
    }

    private var deletionMessage: String {
        switch deletionTarget {
        case .folder:
            "Photos and original files are preserved and remain available in All Photos."
        case .collection:
            "Photos and original files are preserved; only this collection is removed."
        case nil:
            ""
        }
    }

    private func beginCreatingFolder() {
        nameDraft = "New Folder"
        namingTarget = .newFolder
    }

    private func beginCreatingCollection() {
        nameDraft = "New Collection"
        namingTarget = .newCollection
    }

    private func beginRenaming(_ folder: LibraryFolder) {
        nameDraft = folder.name
        namingTarget = .folder(folder)
    }

    private func beginRenaming(_ collection: AssetCollection) {
        nameDraft = collection.name
        namingTarget = .collection(collection)
    }

    private func commitName() {
        guard let namingTarget else { return }
        let name = nameDraft
        self.namingTarget = nil
        switch namingTarget {
        case .newFolder:
            onCreateFolder(name)
        case .newCollection:
            onCreateCollection(name)
        case .folder(let folder):
            onRenameFolder(folder, name)
        case .collection(let collection):
            onRenameCollection(collection, name)
        }
    }

    private func commitDeletion() {
        guard let deletionTarget else { return }
        self.deletionTarget = nil
        switch deletionTarget {
        case .folder(let folder):
            onDeleteFolder(folder)
        case .collection(let collection):
            onDeleteCollection(collection)
        }
    }
}
