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
    @Binding var selectedAsset: ImageAsset?
    var onOpen: (ImageAsset) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var cellSize: Double = 180

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
                                isSelected: selectedAsset?.persistentModelID == asset.persistentModelID
                            )
                            .onTapGesture { selectedAsset = asset }
                            .onTapGesture(count: 2) { onOpen(asset) }
                            .contextMenu { contextMenu(for: asset) }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .background(Theme.canvas)
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for asset: ImageAsset) -> some View {
        Button {
            onOpen(asset)
        } label: { Label("Open", systemImage: "arrow.up.left.and.arrow.down.right") }

        Button {
            asset.flag = (asset.flag == .picked) ? .unflagged : .picked
        } label: { Label("Pick", systemImage: "flag") }

        Button {
            asset.flag = (asset.flag == .rejected) ? .unflagged : .rejected
        } label: { Label("Reject", systemImage: "xmark.circle") }

        Menu("Rating") {
            ForEach(0...5, id: \.self) { stars in
                Button {
                    asset.rating = stars
                } label: {
                    Text(stars == 0 ? "None" : String(repeating: "★", count: stars))
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            remove(asset)
        } label: { Label("Remove from Library", systemImage: "trash") }
    }

    /// Removes the catalog record (and its cached thumbnail). The original file
    /// is left untouched on disk — a re-scan/import will pick it up again.
    private func remove(_ asset: ImageAsset) {
        if selectedAsset?.persistentModelID == asset.persistentModelID {
            selectedAsset = nil
        }
        let id = asset.id
        modelContext.delete(asset)
        Task { await ThumbnailService.shared.invalidate(id) }
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

            if let selectedAsset {
                Button { onOpen(selectedAsset) } label: {
                    Label("Open", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
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
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                AsyncThumbnail(asset: asset)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                overlays.padding(6)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 3)
            )

            Text(asset.originalFilename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
        }
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
            Text("Use Import to add RAW files, or drop them into the\nRawLight folder in the Files app and tap Scan.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}
