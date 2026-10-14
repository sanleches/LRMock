//
//  PhotoGridView.swift
//  RawLight
//
//  Main content: the adaptive grid of imported assets. Single-tap selects,
//  double-tap (or the Open button) opens the loupe.
//

import SwiftUI
import SwiftData

struct PhotoGridView: View {
    let title: String
    let assets: [ImageAsset]
    let folders: [LibraryFolder]
    let collections: [AssetCollection]
    @Binding var selectedAsset: ImageAsset?
    let autosaver: SidecarAutosaver
    var onOpen: (ImageAsset) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var cellSize: Double = 180
    @State private var isSelecting = false
    @State private var selectedAssetIDs: Set<UUID> = []
    @State private var assetsPendingRemoval: [ImageAsset] = []
    @State private var operationError: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.6), spacing: 14)]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)

            if assets.isEmpty {
                EmptyLibraryState()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(assets) { asset in
                            AssetGridCell(
                                asset: asset,
                                isFocused: selectedAsset?.id == asset.id,
                                isSelected: selectedAssetIDs.contains(asset.id),
                                showsSelection: isSelecting
                            )
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                guard !isSelecting else { return }
                                onOpen(asset)
                            }
                            .onTapGesture { handleTap(on: asset) }
                            .contextMenu { contextMenu(for: asset) }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .background(Theme.canvas)
        .accessibilityIdentifier("photo-grid")
        .onChange(of: assets.map(\.id)) { _, ids in
            pruneSelection(to: Set(ids))
        }
        .confirmationDialog(
            removalTitle,
            isPresented: removalPresented,
            titleVisibility: .visible
        ) {
            Button("Remove from Library", role: .destructive) {
                removeFromLibrary(assetsPendingRemoval)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "Unknown error")
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for asset: ImageAsset) -> some View {
        Button {
            onOpen(asset)
        } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }

        Button {
            beginSelection(with: asset)
        } label: { Label("Select Photo", systemImage: "checkmark.circle") }

        Divider()

        Button {
            setFlag(.picked, for: [asset])
        } label: { Label("Mark as Pick", systemImage: "flag") }

        Button {
            setFlag(.rejected, for: [asset])
        } label: { Label("Mark as Rejected", systemImage: "xmark.circle") }

        Button {
            setFlag(.unflagged, for: [asset])
        } label: { Label("Clear Flag", systemImage: "flag.slash") }

        Menu("Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button {
                    setRating(stars, for: [asset])
                } label: {
                    Text(stars == 0 ? "None" : String(repeating: "★", count: stars))
                }
            }
        }

        Divider()

        Menu("Move to Folder") {
            folderActions(for: [asset])
        }

        if !collections.isEmpty {
            Menu("Add to Collection") {
                collectionAddActions(for: [asset])
            }
        }

        let memberships = collectionsContaining(anyOf: [asset])
        if !memberships.isEmpty {
            Menu("Remove from Collection") {
                collectionRemoveActions(for: [asset], collections: memberships)
            }
        }

        Divider()

        Button {
            DevelopClipboard.copy(asset.develop, from: clipboardSource(for: asset))
        } label: { Label("Copy Settings", systemImage: "doc.on.doc") }

        Button {
            let targetSource = clipboardSource(for: asset)
            mutateDevelop(asset) {
                DevelopClipboard.paste(onto: &asset.develop, targetSource: targetSource)
            }
        } label: { Label("Paste Settings", systemImage: "doc.on.clipboard") }
            .disabled(!DevelopClipboard.hasSettings)

        Divider()

        Button(role: .destructive) {
            assetsPendingRemoval = [asset]
        } label: { Label("Remove from Library", systemImage: "trash") }
    }

    private func clipboardSource(for asset: ImageAsset) -> DevelopClipboard.SourceIdentity {
        DevelopClipboard.SourceIdentity(
            libraryIdentifier: LibraryLocations.currentGeneration.standardizedFileURL.path,
            assetID: asset.id,
            contentDigest: asset.contentDigest,
            fingerprint: asset.fingerprint
        )
    }

    @ViewBuilder
    private var bulkActions: some View {
        Menu {
            Menu("Rating") {
                ForEach(0...5, id: \.self) { stars in
                    Button(stars == 0 ? "No Rating" : String(repeating: "★", count: stars)) {
                        setRating(stars, for: selectedAssets)
                    }
                }
            }

            Menu("Flag") {
                Button("Mark as Pick") { setFlag(.picked, for: selectedAssets) }
                Button("Mark as Rejected") { setFlag(.rejected, for: selectedAssets) }
                Button("Clear Flag") { setFlag(.unflagged, for: selectedAssets) }
            }

            Menu("Move to Folder") {
                folderActions(for: selectedAssets)
            }

            if !collections.isEmpty {
                Menu("Add to Collection") {
                    collectionAddActions(for: selectedAssets)
                }
            }

            let memberships = collectionsContaining(anyOf: selectedAssets)
            if !memberships.isEmpty {
                Menu("Remove from Collection") {
                    collectionRemoveActions(for: selectedAssets, collections: memberships)
                }
            }

            Divider()
            Button("Remove from Library", role: .destructive) {
                assetsPendingRemoval = selectedAssets
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("bulk-actions-menu")
        .disabled(selectedAssetIDs.isEmpty)
    }

    @ViewBuilder
    private func folderActions(for subjects: [ImageAsset]) -> some View {
        Button {
            move(subjects, to: nil)
        } label: {
            Label("No Folder", systemImage: all(subjects, areIn: nil) ? "checkmark" : "tray")
        }
        Divider()
        ForEach(folders) { folder in
            Button {
                move(subjects, to: folder)
            } label: {
                Label(
                    folder.name,
                    systemImage: all(subjects, areIn: folder) ? "checkmark" : "folder"
                )
            }
        }
    }

    @ViewBuilder
    private func collectionAddActions(for subjects: [ImageAsset]) -> some View {
        ForEach(collections) { collection in
            let alreadyContainsAll = subjects.allSatisfy { subject in
                subject.collections.contains { $0.id == collection.id }
            }
            Button {
                add(subjects, to: collection)
            } label: {
                Label(
                    collection.name,
                    systemImage: alreadyContainsAll ? "checkmark" : collection.symbol
                )
            }
            .disabled(alreadyContainsAll)
        }
    }

    @ViewBuilder
    private func collectionRemoveActions(
        for subjects: [ImageAsset],
        collections memberships: [AssetCollection]
    ) -> some View {
        ForEach(memberships) { collection in
            Button {
                remove(subjects, from: collection)
            } label: {
                Label(collection.name, systemImage: "minus.circle")
            }
        }
    }

    // MARK: Selection and mutations

    private var selectedAssets: [ImageAsset] {
        assets.filter { selectedAssetIDs.contains($0.id) }
    }

    private var mutations: LibraryMutationService {
        LibraryMutationService(modelContext: modelContext)
    }

    private var removalPresented: Binding<Bool> {
        Binding(
            get: { !assetsPendingRemoval.isEmpty },
            set: { if !$0 { assetsPendingRemoval = [] } }
        )
    }

    private var removalTitle: String {
        assetsPendingRemoval.count == 1
            ? "Remove Photo?"
            : "Remove \(assetsPendingRemoval.count) Photos?"
    }

    private var removalMessage: String {
        let hasManaged = assetsPendingRemoval.contains { $0.storageMode == .managed }
        let hasReferenced = assetsPendingRemoval.contains { $0.storageMode == .referenced }
        switch (hasManaged, hasReferenced) {
        case (true, true):
            return "Managed originals and recipes move to RawLight Trash. Referenced originals and sidecars remain untouched."
        case (true, false):
            return "Managed originals and recipes move to RawLight Trash so they remain recoverable."
        case (false, true):
            return "Only catalog records are removed. Referenced originals and sidecars remain untouched."
        default:
            return "No photos will be removed."
        }
    }

    private func handleTap(on asset: ImageAsset) {
        if isSelecting {
            if selectedAssetIDs.contains(asset.id) {
                selectedAssetIDs.remove(asset.id)
            } else {
                selectedAssetIDs.insert(asset.id)
            }
        } else {
            selectedAsset = asset
        }
    }

    private func beginSelection(with asset: ImageAsset? = nil) {
        isSelecting = true
        selectedAsset = nil
        if let asset { selectedAssetIDs.insert(asset.id) }
    }

    private func endSelection() {
        isSelecting = false
        selectedAssetIDs.removeAll()
    }

    private func toggleSelectAll() {
        let allIDs = Set(assets.map(\.id))
        if selectedAssetIDs == allIDs {
            selectedAssetIDs.removeAll()
        } else {
            selectedAssetIDs = allIDs
        }
    }

    private func pruneSelection(to availableIDs: Set<UUID>) {
        selectedAssetIDs.formIntersection(availableIDs)
        if let selectedAsset, !availableIDs.contains(selectedAsset.id) {
            self.selectedAsset = nil
        }
        if isSelecting, selectedAssetIDs.isEmpty, availableIDs.isEmpty {
            isSelecting = false
        }
    }

    private func setRating(_ rating: Int, for subjects: [ImageAsset]) {
        do {
            try mutations.setRating(rating, for: subjects)
            persistPortableMetadata(for: subjects)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func setFlag(_ flag: PickFlag, for subjects: [ImageAsset]) {
        do {
            try mutations.setFlag(flag, for: subjects)
            persistPortableMetadata(for: subjects)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func move(_ subjects: [ImageAsset], to folder: LibraryFolder?) {
        do {
            try mutations.move(subjects, to: folder)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func add(_ subjects: [ImageAsset], to collection: AssetCollection) {
        do {
            try mutations.add(subjects, to: collection)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func remove(_ subjects: [ImageAsset], from collection: AssetCollection) {
        do {
            try mutations.remove(subjects, from: collection)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func removeFromLibrary(_ subjects: [ImageAsset]) {
        do {
            let removedIDs = try mutations.removeFromLibrary(subjects)
            let removed = Set(removedIDs)
            selectedAssetIDs.subtract(removed)
            if let selectedAsset, removed.contains(selectedAsset.id) {
                self.selectedAsset = nil
            }
            assetsPendingRemoval = []
            if selectedAssetIDs.isEmpty { isSelecting = false }
            Task {
                for id in removedIDs {
                    await ThumbnailService.shared.invalidate(id)
                }
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func mutateDevelop(_ asset: ImageAsset, _ mutation: () -> Void) {
        mutation()
        do {
            try modelContext.save()
            persistPortableMetadata(for: [asset])
        } catch {
            modelContext.rollback()
            operationError = error.localizedDescription
        }
    }

    private func persistPortableMetadata(for subjects: [ImageAsset]) {
        Task {
            for asset in subjects {
                await autosaver.flush(asset)
            }
        }
    }

    private func all(_ subjects: [ImageAsset], areIn folder: LibraryFolder?) -> Bool {
        guard !subjects.isEmpty else { return false }
        return subjects.allSatisfy { $0.folder?.id == folder?.id }
    }

    private func collectionsContaining(anyOf subjects: [ImageAsset]) -> [AssetCollection] {
        let subjectIDs = Set(subjects.map(\.id))
        return collections.filter { collection in
            collection.assets.contains { subjectIDs.contains($0.id) }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(assets.count) photos")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()

            if isSelecting {
                Text("\(selectedAssetIDs.count) selected")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)

                Button(selectedAssetIDs.count == assets.count ? "Deselect All" : "Select All") {
                    toggleSelectAll()
                }
                .disabled(assets.isEmpty)

                bulkActions

                Button("Done") { endSelection() }
                    .keyboardShortcut(.escape, modifiers: [])
            } else if let selectedAsset {
                Button { onOpen(selectedAsset) } label: {
                    Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }

            if !isSelecting {
                Button {
                    beginSelection()
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("select-photos-button")
                .disabled(assets.isEmpty)
            }

            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3").foregroundStyle(Theme.textSecondary)
                Slider(value: $cellSize, in: 120...260).frame(width: 110).tint(Theme.accent)
                Image(systemName: "square.grid.2x2").foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Theme.canvas)
    }
}

/// A single thumbnail cell with rating / flag / edited overlays.
struct AssetGridCell: View {
    let asset: ImageAsset
    let isFocused: Bool
    let isSelected: Bool
    let showsSelection: Bool

    var body: some View {
        VStack(spacing: 6) {
            // A fixed-size square defined by `Color.clear`; the thumbnail is an
            // overlay so its `scaledToFill` overflow is clipped and can never
            // affect the cell's layout (which was causing cells to collide).
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { AsyncThumbnail(asset: asset) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { overlays.padding(6) }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isSelected || isFocused ? Theme.accent : .clear,
                            lineWidth: isSelected ? 3 : 2
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if showsSelection {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3.weight(.semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                isSelected ? Color.white : Color.white.opacity(0.9),
                                isSelected ? Theme.accent : Color.black.opacity(0.5)
                            )
                            .padding(8)
                    }
                }

            Text(asset.originalFilename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected || isFocused ? Theme.textPrimary : Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(asset.originalFilename)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("asset-\(asset.id.uuidString)")
    }

    private var overlays: some View {
        VStack {
            HStack {
                if asset.flag == .picked {
                    badge(system: "flag.fill", tint: .green)
                } else if asset.flag == .rejected {
                    badge(system: "xmark", tint: .red)
                }
                Spacer()
                if asset.hasEdits {
                    badge(system: "slider.horizontal.3", tint: .black.opacity(0.5))
                }
                if asset.isMissing {
                    badge(system: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
            Spacer()
            if asset.rating > 0 {
                HStack(spacing: 2) {
                    ForEach(0..<asset.rating, id: \.self) { _ in
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                }
                .padding(4)
                .background(.black.opacity(0.4), in: Capsule())
            }
        }
    }

    private func badge(system: String, tint: Color) -> some View {
        Image(systemName: system)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(4)
            .background(tint, in: Circle())
    }
}

/// Shown when the selected library section has no photos.
struct EmptyLibraryState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 52))
                .foregroundStyle(Theme.textTertiary)
            Text("No photos here yet")
                .font(.headline)
                .foregroundStyle(Theme.textSecondary)
            Text("Use Import to copy photos into RawLight, or reference an existing folder in place.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .accessibilityIdentifier("empty-library-state")
    }
}
