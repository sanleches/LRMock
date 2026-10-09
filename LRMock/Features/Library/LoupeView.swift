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

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showInspector = true
    @State private var showExport = false
    @State private var cropMode = false
    @State private var comparing = false
    @State private var autosaver = SidecarAutosaver()
    @State private var renderedImage: CGImage?
    @State private var renderVersion = 0

    var body: some View {
        Group {
            if cropMode, let asset = selectedAsset {
                CropView(asset: asset, onDone: { withAnimation { cropMode = false } })
            } else {
                editorBody
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showExport) {
            if let asset = selectedAsset { ExportSheet(asset: asset) }
        }
        // Live, debounced sidecar autosave while editing.
        .onChange(of: selectedAsset?.develop) { _, _ in scheduleAutosave() }
        .onChange(of: selectedAsset?.rating) { _, _ in scheduleAutosave() }
        .onChange(of: selectedAsset?.flagRaw) { _, _ in scheduleAutosave() }
        .onChange(of: selectedAsset?.persistentModelID) { oldID, _ in
            if let oldID, let previous = assets.first(where: { $0.persistentModelID == oldID }) {
                autosaver.flush(previous)
            }
            renderedImage = nil
            renderVersion &+= 1
            comparing = false
            saveCatalog()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushEdits() }
        }
        .onDisappear(perform: flushEdits)
        .alert("Edits Could Not Be Saved", isPresented: Binding(
            get: { autosaver.lastError != nil },
            set: { if !$0 { autosaver.dismissError() } }
        )) {
            Button("OK", role: .cancel) { autosaver.dismissError() }
        } message: {
            Text(autosaver.lastError ?? "Unknown error")
        }
    }

    private var editorBody: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.separator)

            HStack(spacing: 0) {
                ZStack {
                    Theme.canvas
                    if let asset = selectedAsset {
                        LoupeStage(asset: asset, comparing: $comparing) { cg in
                            renderedImage = cg
                            renderVersion &+= 1
                        }
                        .padding(24)
                        .id(asset.persistentModelID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector, let asset = selectedAsset {
                    Divider().overlay(Theme.separator)
                    InspectorPanel(asset: asset,
                                   renderedImage: renderedImage,
                                   renderVersion: renderVersion)
                        .transition(.move(edge: .trailing))
                }
            }

            Divider().overlay(Theme.separator)
            filmstrip
        }
    }

    private func scheduleAutosave() {
        if let asset = selectedAsset { autosaver.schedule(asset) }
    }

    private func flushEdits() {
        saveCatalog()
        autosaver.flushAll()
    }

    private func saveCatalog() {
        do {
            try modelContext.save()
        } catch {
            autosaver.lastError = error.localizedDescription
        }
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
                .help(asset.flag == .picked ? "Remove Pick Flag" : "Mark as Pick")
            }

            Spacer()

            Button { comparing.toggle() } label: {
                Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
                    .foregroundStyle(comparing ? Theme.accent : Theme.textSecondary)
            }
            .help("Before / After (hold the image to peek the original)")
            .disabled(selectedAsset == nil)

            Button { withAnimation { cropMode = true } } label: {
                Image(systemName: "crop").foregroundStyle(
                    selectedAsset?.develop.hasGeometry == true ? Theme.accent : Theme.textSecondary)
            }
            .help("Crop and Rotate")
            .disabled(selectedAsset == nil)

            Button { showExport = true } label: {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.accent)
            }
            .help("Export")
            .disabled(selectedAsset == nil)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showInspector ? Theme.accent : Theme.textSecondary)
            }
            .help(showInspector ? "Hide Inspector" : "Show Inspector")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private func ratingStars(for asset: ImageAsset) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    asset.rating = (asset.rating == star) ? 0 : star
                } label: {
                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                        .foregroundStyle(star <= asset.rating ? .yellow : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(star) star rating")
                .accessibilityValue(asset.rating == star ? "Selected" : "")
            }
        }
        .font(.system(size: 14))
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(assets) { asset in
                        Button {
                            withAnimation { selectedAsset = asset }
                        } label: {
                            AsyncThumbnail(asset: asset, maxPixelSize: 192)
                                .frame(width: 96, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(
                                            selectedAsset?.persistentModelID == asset.persistentModelID
                                                ? Theme.accent : .clear,
                                            lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(asset.originalFilename)
                        .accessibilityAddTraits(
                            selectedAsset?.persistentModelID == asset.persistentModelID ? .isSelected : []
                        )
                        .id(asset.persistentModelID)
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
