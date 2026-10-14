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
    let autosaver: SidecarAutosaver
    var onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(macOS)
    @State private var showInspector = true
    #else
    @State private var showInspector = false
    #endif
    @State private var showExport = false
    @State private var cropMode = false
    @State private var comparing = false
    @State private var renderedImage: CGImage?
    @State private var renderVersion = 0
    @State private var developHistory = DevelopHistoryCoordinator()
    @State private var developToolSession = DevelopToolSession()
    @State private var cropHistoryTransaction: DevelopHistoryTransaction?

    var body: some View {
        #if os(iOS)
        loupeContent
            .sheet(isPresented: compactInspectorPresentation) {
                if let asset = selectedAsset {
                    inspector(for: asset)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Theme.panel)
                }
            }
        #else
        loupeContent
        #endif
    }

    private var loupeContent: some View {
        Group {
            if cropMode, let asset = selectedAsset {
                CropView(asset: asset, onDone: finishCrop)
            } else {
                editorBody
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showExport) {
            if let asset = selectedAsset { ExportSheet(asset: asset) }
        }
        .overlay(alignment: .topLeading) { developShortcutHandlers }
        // Live, debounced sidecar autosave while editing.
        .onChange(of: selectedAsset?.develop) { _, _ in scheduleAutosave() }
        .onChange(of: selectedAsset?.rating) { _, _ in scheduleAutosave() }
        .onChange(of: selectedAsset?.flagRaw) { _, _ in scheduleAutosave() }
        .onChange(of: selectedAsset?.persistentModelID) { oldID, _ in
            if let oldID, let previous = assets.first(where: { $0.persistentModelID == oldID }) {
                finishCropHistory(for: previous)
                finishCanvasHistory(for: previous)
                Task { await autosaver.flush(previous) }
            }
            developHistory.activate(assetID: selectedAsset?.id)
            developToolSession.resetForAsset()
            renderedImage = nil
            renderVersion &+= 1
            comparing = false
            saveCatalog()
        }
        .onAppear {
            developHistory.activate(assetID: selectedAsset?.id)
            #if os(iOS)
            if horizontalSizeClass == .regular { showInspector = true }
            #endif
        }
        .onDisappear { finishActiveEdit(returnToNavigate: true) }
    }

    private var editorBody: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.separator)

            editorContent

            Divider().overlay(Theme.separator)
            filmstrip
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            editorCanvas
        } else {
            editorWithInspector
        }
        #else
        editorWithInspector
        #endif
    }

    private var editorWithInspector: some View {
        HStack(spacing: 0) {
            editorCanvas
            if showInspector, let asset = selectedAsset {
                Divider().overlay(Theme.separator)
                inspector(for: asset)
                .frame(width: 310)
                .transition(.move(edge: .trailing))
            }
        }
    }

    private var editorCanvas: some View {
        ZStack(alignment: .top) {
            Theme.canvas
            if let asset = selectedAsset {
                LoupeStage(
                    asset: asset,
                    comparing: $comparing,
                    session: developToolSession,
                    history: developHistory
                ) { cg in
                    renderedImage = cg
                    renderVersion &+= 1
                }
                .padding(canvasPadding)
                .id(asset.persistentModelID)
            }

            if developToolSession.tool.isEditing {
                toolHUD
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inspector(for asset: ImageAsset) -> some View {
        InspectorPanel(
            asset: asset,
            session: developToolSession,
            history: developHistory,
            renderedImage: renderedImage,
            renderVersion: renderVersion,
            onActivateTool: { tool in
                if activateTool(tool), horizontalSizeClass == .compact {
                    showInspector = false
                }
            }
        )
    }

    private var canvasPadding: CGFloat {
        horizontalSizeClass == .compact ? 12 : 24
    }

    private func scheduleAutosave() {
        if let asset = selectedAsset { autosaver.schedule(asset) }
    }

    private func beginCrop() {
        guard let asset = selectedAsset else { return }
        finishCanvasHistory(for: asset)
        developToolSession.finish()
        guard let transaction = developHistory.beginChange(
            for: asset.id,
            current: asset.develop
        ) else { return }
        cropHistoryTransaction = transaction
        withAnimation { cropMode = true }
    }

    private func finishCrop() {
        if let asset = selectedAsset {
            finishCropHistory(for: asset)
        }
        withAnimation { cropMode = false }
    }

    private func finishActiveEdit(returnToNavigate: Bool) {
        if let asset = selectedAsset {
            finishCropHistory(for: asset)
            finishCanvasHistory(for: asset)
        }
        if returnToNavigate {
            developToolSession.finish()
        } else {
            developToolSession.clearActiveGesture()
        }
    }

    private func finishCropHistory(for asset: ImageAsset) {
        guard let transaction = cropHistoryTransaction else { return }
        cropHistoryTransaction = nil
        developHistory.endChange(transaction, current: asset.develop)
    }

    private func finishCanvasHistory(for asset: ImageAsset) {
        guard let transaction = developToolSession.activeHistoryTransaction else { return }
        developToolSession.activeHistoryTransaction = nil
        developHistory.endChange(transaction, current: asset.develop)
    }

    private func undoDevelop() {
        guard let asset = selectedAsset,
              let settings = developHistory.undo(for: asset.id, current: asset.develop)
        else { return }
        asset.develop = settings
    }

    private func redoDevelop() {
        guard let asset = selectedAsset,
              let settings = developHistory.redo(for: asset.id, current: asset.develop)
        else { return }
        asset.develop = settings
    }

    private func closeLoupe() {
        finishActiveEdit(returnToNavigate: true)
        onClose()
    }

    @discardableResult
    private func activateTool(_ tool: DevelopToolSession.Tool) -> Bool {
        guard let asset = selectedAsset,
              DevelopToolAvailability.canActivate(
                tool,
                settings: asset.develop,
                selectedMaskID: developToolSession.selectedMaskID
              ) else { return false }
        finishActiveEdit(returnToNavigate: false)
        if tool == .navigate {
            developToolSession.finish()
        } else {
            comparing = false
            developToolSession.activate(tool)
        }
        return true
    }

    private func saveCatalog() {
        do {
            try modelContext.save()
        } catch {
            autosaver.lastError = error.localizedDescription
        }
    }

    // MARK: Toolbar

    private var developShortcutHandlers: some View {
        VStack(spacing: 0) {
            Button(action: undoDevelop) { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!developHistory.canUndo)
            Button(action: redoDevelop) { Color.clear.frame(width: 0, height: 0) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!developHistory.canRedo)
        }
        .frame(width: 0, height: 0)
        .clipped()
        .accessibilityHidden(true)
    }

    private var toolbar: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactToolbar
            } else {
                regularToolbar
            }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 8 : 20)
        .padding(.vertical, toolbarVerticalPadding)
        .background(Theme.panel)
    }

    private var regularToolbar: some View {
        HStack(spacing: 16) {
            Button(action: closeLoupe) {
                Label("Grid", systemImage: "square.grid.2x2")
                    .frame(minHeight: toolbarControlSize)
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
                        .frame(minWidth: toolbarControlSize, minHeight: toolbarControlSize)
                }
                .help(asset.flag == .picked ? "Remove Pick Flag" : "Mark as Pick")
            }

            Spacer()

            toolsMenu
            compareButton
            cropButton
            exportButton
            inspectorButton
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 2) {
            Button(action: closeLoupe) {
                Image(systemName: "square.grid.2x2")
                    .frame(width: toolbarControlSize, height: toolbarControlSize)
            }
            .tint(Theme.accent)
            .accessibilityLabel("Grid")

            if let asset = selectedAsset {
                Text(asset.originalFilename)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)

                Menu {
                    Menu("Rating") {
                        ForEach(0...5, id: \.self) { stars in
                            Button(stars == 0 ? "No Rating" : "\(stars) Stars") {
                                asset.rating = stars
                            }
                        }
                    }
                    Button(asset.flag == .picked ? "Remove Pick Flag" : "Mark as Pick") {
                        asset.flag = (asset.flag == .picked) ? .unflagged : .picked
                    }
                } label: {
                    Image(systemName: asset.flag == .picked ? "flag.fill" : "ellipsis.circle")
                        .foregroundStyle(asset.flag == .picked ? .green : Theme.textSecondary)
                        .frame(width: toolbarControlSize, height: toolbarControlSize)
                }
                .accessibilityLabel("Rating and Flag")
            }

            toolsMenu
            compareButton
            cropButton
            exportButton
            inspectorButton
        }
    }

    private var compareButton: some View {
        Button {
            finishActiveEdit(returnToNavigate: false)
            comparing.toggle()
        } label: {
            Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
                .foregroundStyle(comparing ? Theme.accent : Theme.textSecondary)
                .frame(width: toolbarControlSize, height: toolbarControlSize)
        }
        .help("Before / After (hold the image to peek the original)")
        .disabled(selectedAsset == nil)
        .accessibilityLabel("Before and After")
    }

    private var cropButton: some View {
        Button(action: beginCrop) {
            Image(systemName: "crop")
                .foregroundStyle(
                    selectedAsset?.develop.hasGeometry == true ? Theme.accent : Theme.textSecondary
                )
                .frame(width: toolbarControlSize, height: toolbarControlSize)
        }
        .help("Crop and Rotate")
        .disabled(selectedAsset == nil)
        .accessibilityLabel("Crop and Rotate")
    }

    private var exportButton: some View {
        Button {
            finishActiveEdit(returnToNavigate: false)
            showExport = true
        } label: {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(Theme.accent)
                .frame(width: toolbarControlSize, height: toolbarControlSize)
        }
        .help("Export")
        .disabled(selectedAsset == nil)
        .accessibilityLabel("Export")
    }

    private var inspectorButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
        } label: {
            Image(systemName: "sidebar.right")
                .foregroundStyle(showInspector ? Theme.accent : Theme.textSecondary)
                .frame(width: toolbarControlSize, height: toolbarControlSize)
        }
        .help(showInspector ? "Hide Inspector" : "Show Inspector")
        .disabled(selectedAsset == nil)
        .accessibilityLabel(showInspector ? "Hide Inspector" : "Show Inspector")
    }

    private var toolsMenu: some View {
        Menu {
            ForEach(DevelopToolSession.Tool.allCases) { tool in
                Button {
                    activateTool(tool)
                } label: {
                    Label(
                        tool.title,
                        systemImage: developToolSession.tool == tool ? "checkmark" : tool.icon
                    )
                }
                .disabled(!canActivateTool(tool))
                .accessibilityAddTraits(developToolSession.tool == tool ? .isSelected : [])
            }
        } label: {
            Image(systemName: developToolSession.tool.icon)
                .foregroundStyle(developToolSession.tool.isEditing ? Theme.accent : Theme.textSecondary)
                .frame(width: toolbarControlSize, height: toolbarControlSize)
        }
        .help("Selective Develop Tools")
        .disabled(selectedAsset == nil)
        .accessibilityLabel("Tools")
        .accessibilityValue(developToolSession.tool.title)
    }

    private func canActivateTool(_ tool: DevelopToolSession.Tool) -> Bool {
        guard let asset = selectedAsset else { return false }
        return DevelopToolAvailability.canActivate(
            tool,
            settings: asset.develop,
            selectedMaskID: developToolSession.selectedMaskID
        )
    }

    private var toolHUD: some View {
        HStack(spacing: 6) {
            Label(developToolSession.tool.title, systemImage: developToolSession.tool.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Button {
                developToolSession.overlaysVisible.toggle()
            } label: {
                Image(systemName: developToolSession.overlaysVisible ? "eye" : "eye.slash")
                    .frame(width: hudControlSize, height: hudControlSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel(
                developToolSession.overlaysVisible ? "Hide edit overlays" : "Show edit overlays"
            )

            Button("Done") {
                finishActiveEdit(returnToNavigate: true)
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .frame(minWidth: hudControlSize, minHeight: hudControlSize)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.72), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var hudControlSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    private var compactInspectorPresentation: Binding<Bool> {
        Binding(
            get: { showInspector && horizontalSizeClass == .compact },
            set: { presented in
                if !presented { showInspector = false }
            }
        )
    }

    private var toolbarControlSize: CGFloat {
        #if os(iOS)
        44
        #else
        20
        #endif
    }

    private var toolbarVerticalPadding: CGFloat {
        #if os(iOS)
        4
        #else
        12
        #endif
    }

    private func ratingStars(for asset: ImageAsset) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    asset.rating = (asset.rating == star) ? 0 : star
                } label: {
                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                        .foregroundStyle(star <= asset.rating ? .yellow : Theme.textTertiary)
                        .frame(minWidth: toolbarControlSize, minHeight: toolbarControlSize)
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
                            finishActiveEdit(returnToNavigate: true)
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
            .frame(height: 84)
            .background(Theme.panel)
            .onChange(of: selectedAsset?.persistentModelID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}
