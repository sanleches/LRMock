//
//  LoupeView.swift
//  RawLight
//
//  Full-screen view of a single asset: live develop preview centre-stage, the
//  develop inspector on the right, and a filmstrip for navigation at the bottom.
//

import SwiftUI
import SwiftData

struct LoupeView: View {
    let assets: [ImageAsset]
    @Binding var selectedAsset: ImageAsset?
    var onClose: () -> Void

    @State private var showInspector = true
    @State private var showExport = false
    @State private var autosaver = SidecarAutosaver()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.separator)

            HStack(spacing: 0) {
                ZStack {
                    Theme.canvas
                    if let asset = selectedAsset {
                        DevelopPreview(asset: asset, settings: asset.develop)
                            .padding(24)
                            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                            .id(asset.persistentModelID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector, let asset = selectedAsset {
                    Divider().overlay(Theme.separator)
                    InspectorPanel(asset: asset)
                        .transition(.move(edge: .trailing))
                }
            }

            Divider().overlay(Theme.separator)
            filmstrip
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showExport) {
            if let asset = selectedAsset { ExportSheet(asset: asset) }
        }
        // Live, debounced sidecar autosave while editing.
        .onChange(of: selectedAsset?.develop) { _, _ in scheduleAutosave() }
        .onChange(of: selectedAsset?.rating) { _, _ in scheduleAutosave() }
        .onChange(of: selectedAsset?.flagRaw) { _, _ in scheduleAutosave() }
    }

    private func scheduleAutosave() {
        if let asset = selectedAsset { autosaver.schedule(asset) }
    }

    private func rotate(_ delta: Int) {
        guard let asset = selectedAsset else { return }
        asset.develop.rotationQuarterTurns =
            ((asset.develop.rotationQuarterTurns + delta) % 4 + 4) % 4
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                Label("Grid", systemImage: "square.grid.2x2")
            }
            .tint(Theme.accent)

            Spacer()

            if let asset = selectedAsset {
                Text(asset.originalFilename)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ratingStars(for: asset)

                Button {
                    asset.flag = (asset.flag == .picked) ? .unflagged : .picked
                } label: {
                    Image(systemName: asset.flag == .picked ? "flag.fill" : "flag")
                        .foregroundStyle(asset.flag == .picked ? .green : Theme.textSecondary)
                }
            }

            Spacer()

            Button { rotate(-1) } label: {
                Image(systemName: "rotate.left").foregroundStyle(Theme.textSecondary)
            }
            Button { rotate(1) } label: {
                Image(systemName: "rotate.right").foregroundStyle(Theme.textSecondary)
            }

            Button { showExport = true } label: {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.accent)
            }
            .disabled(selectedAsset == nil)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showInspector ? Theme.accent : Theme.textSecondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private func ratingStars(for asset: ImageAsset) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= asset.rating ? "star.fill" : "star")
                    .foregroundStyle(star <= asset.rating ? .yellow : Theme.textTertiary)
                    .onTapGesture { asset.rating = (asset.rating == star) ? 0 : star }
            }
        }
        .font(.system(size: 14))
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(assets) { asset in
                        AsyncThumbnail(asset: asset)
                            .frame(width: 96, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(
                                        selectedAsset?.persistentModelID == asset.persistentModelID
                                            ? Theme.accent : .clear,
                                        lineWidth: 2)
                            )
                            .id(asset.persistentModelID)
                            .onTapGesture { withAnimation { selectedAsset = asset } }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Theme.panel)
            .onChange(of: selectedAsset?.persistentModelID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}
