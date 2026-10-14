//
//  LoupeStage.swift
//  RawLight
//
//  The image stage inside the loupe: the live develop preview with
//    - pinch / trackpad-magnify zoom + pan, double-tap to toggle fit <-> 2x
//    - press-and-hold to peek the original ("before")
//    - a persistent Before/After toggle (driven from the toolbar)
//

import SwiftUI

/// Pure zoom geometry shared by the gestures and unit tests. Scale 1 is always
/// fit-to-view; offsets are measured in viewport points from the fitted center.
struct LoupeZoomState: Equatable {
    static let fitScale: CGFloat = 1
    static let toggleScale: CGFloat = 2
    static let maximumScale: CGFloat = 8

    private(set) var scale: CGFloat = fitScale
    private(set) var offset: CGSize = .zero

    var isFit: Bool { scale <= Self.fitScale + 0.0001 }

    mutating func reset() {
        scale = Self.fitScale
        offset = .zero
    }

    mutating func toggle(at location: CGPoint, in viewport: CGSize, contentSize: CGSize) {
        if isFit {
            zoom(to: Self.toggleScale, at: location, in: viewport, contentSize: contentSize)
        } else {
            reset()
        }
    }

    mutating func magnify(
        by magnification: CGFloat,
        at location: CGPoint,
        in viewport: CGSize,
        contentSize: CGSize
    ) {
        guard magnification.isFinite, magnification > 0 else { return }
        zoom(to: scale * magnification, at: location, in: viewport, contentSize: contentSize)
    }

    mutating func zoom(
        to proposedScale: CGFloat,
        at location: CGPoint,
        in viewport: CGSize,
        contentSize: CGSize
    ) {
        clamp(to: viewport, contentSize: contentSize)

        guard proposedScale.isFinite else { return }
        let nextScale = min(Self.maximumScale, max(Self.fitScale, proposedScale))
        guard nextScale > Self.fitScale + 0.0001 else {
            reset()
            return
        }

        let previousScale = scale
        scale = nextScale

        guard Self.isValid(viewport), Self.isValid(contentSize) else {
            offset = .zero
            return
        }

        let anchor = CGPoint(
            x: min(max(location.x, 0), viewport.width),
            y: min(max(location.y, 0), viewport.height)
        )
        let anchorFromCenter = CGSize(
            width: anchor.x - viewport.width / 2,
            height: anchor.y - viewport.height / 2
        )
        let scaleChange = nextScale / previousScale

        // Keep the image point under the gesture anchor stationary as it scales.
        offset = CGSize(
            width: anchorFromCenter.width
                - scaleChange * (anchorFromCenter.width - offset.width),
            height: anchorFromCenter.height
                - scaleChange * (anchorFromCenter.height - offset.height)
        )
        clamp(to: viewport, contentSize: contentSize)
    }

    mutating func pan(by translation: CGSize, in viewport: CGSize, contentSize: CGSize) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        offset.width += translation.width
        offset.height += translation.height
        clamp(to: viewport, contentSize: contentSize)
    }

    mutating func clamp(to viewport: CGSize, contentSize: CGSize) {
        guard scale.isFinite else {
            reset()
            return
        }
        scale = min(Self.maximumScale, max(Self.fitScale, scale))

        guard !isFit else {
            reset()
            return
        }
        guard Self.isValid(viewport), Self.isValid(contentSize) else {
            offset = .zero
            return
        }

        let maximumOffset = CGSize(
            width: max(0, (contentSize.width * scale - viewport.width) / 2),
            height: max(0, (contentSize.height * scale - viewport.height) / 2)
        )
        offset = CGSize(
            width: min(max(offset.width.isFinite ? offset.width : 0, -maximumOffset.width),
                       maximumOffset.width),
            height: min(max(offset.height.isFinite ? offset.height : 0, -maximumOffset.height),
                        maximumOffset.height)
        )
    }

    static func fittedContentSize(aspectRatio: CGFloat, in viewport: CGSize) -> CGSize {
        guard aspectRatio.isFinite, aspectRatio > 0, isValid(viewport) else { return .zero }
        if aspectRatio > viewport.width / viewport.height {
            return CGSize(width: viewport.width, height: viewport.width / aspectRatio)
        }
        return CGSize(width: viewport.height * aspectRatio, height: viewport.height)
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

nonisolated struct LoupeRenderedGeometryKey: nonisolated Equatable, Sendable {
    let assetID: UUID
    let flipH: Bool
    let flipV: Bool
    let rotationQuarterTurns: Int
    let straighten: Double
    let cropX: Double
    let cropY: Double
    let cropW: Double
    let cropH: Double
    let vertical: Double
    let horizontal: Double
    let aspect: Double
    let scale: Double
    let offsetX: Double
    let offsetY: Double

    init(assetID: UUID, settings: DevelopSettings) {
        self.assetID = assetID
        self.flipH = settings.flipH
        self.flipV = settings.flipV
        self.rotationQuarterTurns = settings.rotationQuarterTurns
        self.straighten = settings.straighten
        self.cropX = settings.cropX
        self.cropY = settings.cropY
        self.cropW = settings.cropW
        self.cropH = settings.cropH
        self.vertical = settings.geometryVertical
        self.horizontal = settings.geometryHorizontal
        self.aspect = settings.geometryAspect
        self.scale = settings.geometryScale
        self.offsetX = settings.geometryOffsetX
        self.offsetY = settings.geometryOffsetY
    }
}

struct LoupeStage: View {
    let asset: ImageAsset
    /// Persistent Before/After toggle from the toolbar.
    @Binding var comparing: Bool
    let session: DevelopToolSession
    let history: DevelopHistoryCoordinator
    var onRender: (CGImage) -> Void

    @State private var zoomState = LoupeZoomState()
    @State private var renderedAspectFrame: RenderedAspectFrame?
    @State private var pointColorSamplingFrame: PointColorSamplingFrame?
    @State private var pointColorSamplingFailureFrame: PointColorSamplingFailureFrame?
    @State private var activeMagnification: ActiveMagnification?
    @State private var magnificationState = MagnificationGestureState()
    @GestureState private var magnificationGestureActive = false
    @GestureState private var activePan: CGSize = .zero

    // Press-and-hold to peek the original, with a small delay so quick taps
    // don't flash.
    @State private var peeking = false
    @State private var peekTask: Task<Void, Never>?

    private struct ActiveMagnification {
        let amount: CGFloat
        let anchor: UnitPoint
    }

    private struct RenderedAspectFrame {
        let geometryKey: LoupeRenderedGeometryKey
        let aspectRatio: CGFloat
    }

    private struct PointColorSamplingFrame {
        let assetID: UUID
        let settings: DevelopSettings
        let generation: UInt64
        let image: CGImage
    }

    private struct PointColorSamplingFailureFrame {
        let assetID: UUID
        let settings: DevelopSettings
        let generation: UInt64
        let message: String
    }

    private var showingOriginal: Bool { comparing || peeking }

    private var currentGeometryKey: LoupeRenderedGeometryKey {
        LoupeRenderedGeometryKey(assetID: asset.id, settings: asset.develop)
    }

    private var renderedGeometryIsCurrent: Bool {
        renderedAspectFrame?.geometryKey == currentGeometryKey
    }

    private var imageAspectRatio: CGFloat {
        if renderedGeometryIsCurrent, let renderedAspectFrame {
            return renderedAspectFrame.aspectRatio
        }
        return estimatedImageAspectRatio
    }

    private var estimatedImageAspectRatio: CGFloat {
        var aspect = CGFloat(asset.aspectRatio)
        if (5...8).contains(asset.exifOrientation) { aspect = 1 / aspect }

        let turns = ((asset.develop.rotationQuarterTurns % 4) + 4) % 4
        if turns % 2 == 1 { aspect = 1 / aspect }

        let cropWidth = CGFloat(asset.develop.cropW)
        let cropHeight = CGFloat(asset.develop.cropH)
        if cropWidth > 0, cropHeight > 0 { aspect *= cropWidth / cropHeight }
        return aspect.isFinite && aspect > 0 ? aspect : 1.5
    }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let contentSize = LoupeZoomState.fittedContentSize(
                aspectRatio: imageAspectRatio,
                in: viewport
            )
            let displayedZoom = displayedZoom(in: viewport, contentSize: contentSize)
            let fittedImageRect = CGRect(
                x: (viewport.width - contentSize.width) / 2,
                y: (viewport.height - contentSize.height) / 2,
                width: contentSize.width,
                height: contentSize.height
            )
            let viewportTransform = LoupeViewportTransform(
                viewportSize: viewport,
                fittedImageRect: fittedImageRect,
                zoomScale: displayedZoom.scale,
                zoomOffset: displayedZoom.offset,
                cropX: asset.develop.cropX,
                cropY: asset.develop.cropY,
                cropW: asset.develop.cropW,
                cropH: asset.develop.cropH
            )
            let previewSettings = showingOriginal
                ? asset.develop.beforeSettings
                : asset.develop
            let geometryKey = currentGeometryKey
            let geometryReady = renderedAspectFrame?.geometryKey == geometryKey
            let samplingSettings = asset.develop
            let samplingGeneration = session.pointColorSamplingGeneration
            let samplingImage = pointColorSamplingImage(
                matching: samplingSettings,
                generation: samplingGeneration
            )
            let samplingFailure = pointColorSamplingFailure(
                matching: samplingSettings,
                generation: samplingGeneration
            )
            let pointColorSamplingReady = geometryReady && samplingImage != nil

            ZStack {
                DevelopPreview(
                    asset: asset,
                    settings: previewSettings,
                    onRender: { image in
                        guard !showingOriginal else { return }
                        handleRendered(image, geometryKey: geometryKey, in: viewport)
                    }
                )
                .scaleEffect(displayedZoom.scale)
                .offset(displayedZoom.offset)
                .frame(width: viewport.width, height: viewport.height)

                if session.tool == .pointColor, !showingOriginal {
                    DevelopPreview(
                        asset: asset,
                        settings: samplingSettings,
                        renderIntent: .pointColorSampling,
                        onFailure: { failure in
                            guard failure.identity.renderIntent == .pointColorSampling else { return }
                            pointColorSamplingFailureFrame = PointColorSamplingFailureFrame(
                                assetID: failure.identity.assetID,
                                settings: failure.identity.settings,
                                generation: samplingGeneration,
                                message: failure.message
                            )
                        },
                        onRender: { image in
                            pointColorSamplingFailureFrame = nil
                            pointColorSamplingFrame = PointColorSamplingFrame(
                                assetID: asset.id,
                                settings: samplingSettings,
                                generation: samplingGeneration,
                                image: image
                            )
                        }
                    )
                    .id(samplingGeneration)
                    .onAppear { pointColorSamplingFailureFrame = nil }
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                DevelopToolOverlay(
                    asset: asset,
                    session: session,
                    history: history,
                    pointColorSamplingImage: samplingImage,
                    transform: viewportTransform,
                    enabled: session.tool.isEditing
                        && !showingOriginal
                        && geometryReady
                        && (session.tool != .pointColor || pointColorSamplingReady)
                )
                .opacity(showingOriginal || !geometryReady ? 0 : 1)

                if session.tool == .pointColor,
                   !showingOriginal,
                   !pointColorSamplingReady {
                    if let samplingFailure {
                        samplingFailureState(samplingFailure)
                    } else {
                        samplingProgress
                    }
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnifyGesture(in: viewport, contentSize: contentSize))
            .simultaneousGesture(panGesture(in: viewport, contentSize: contentSize))
            .simultaneousGesture(doubleTapGesture(in: viewport, contentSize: contentSize))
            .onChange(of: magnificationGestureActive) { wasActive, isActive in
                if wasActive, !isActive { clearMagnificationGesture() }
            }
            .onLongPressGesture(
                minimumDuration: 0.25,
                maximumDistance: 40,
                pressing: handlePressing,
                perform: {}
            )
            .overlay(alignment: .top) { if showingOriginal { beforeBadge } }
            .animation(.easeOut(duration: 0.12), value: showingOriginal)
            .help(stageHelp)
            .accessibilityLabel("Photo preview, \(asset.originalFilename)")
            .accessibilityValue(accessibilityZoomValue(displayedZoom.scale))
            .accessibilityHint(stageHelp)
            .accessibilityAction(named: Text("Zoom In")) {
                zoomIn(in: viewport, contentSize: contentSize)
            }
            .accessibilityAction(named: Text("Zoom Out")) {
                zoomOut(in: viewport, contentSize: contentSize)
            }
            .accessibilityAction(named: Text("Fit to View")) {
                withAnimation(.easeInOut(duration: 0.2)) { zoomState.reset() }
            }
            .onChange(of: geo.size) { _, newSize in
                let newContentSize = LoupeZoomState.fittedContentSize(
                    aspectRatio: imageAspectRatio,
                    in: newSize
                )
                zoomState.clamp(to: newSize, contentSize: newContentSize)
            }
        }
        .onChange(of: asset.id) { _, _ in resetForAsset() }
        .onChange(of: session.tool) { _, tool in
            if tool.isEditing { cancelPeek() }
            if tool == .pointColor {
                pointColorSamplingFrame = nil
                pointColorSamplingFailureFrame = nil
            }
        }
        .onChange(of: comparing) { _, isComparing in
            renderedAspectFrame = nil
            if isComparing { cancelPeek() }
        }
        .onDisappear {
            peekTask?.cancel()
            clearMagnificationGesture()
        }
    }

    // MARK: Gestures

    private func magnifyGesture(in viewport: CGSize, contentSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .updating($magnificationGestureActive) { _, isActive, _ in
                isActive = true
            }
            .onChanged { value in
                if magnificationState.needsClaim {
                    guard magnificationState.resolveClaim(
                        session.claimGesture(.magnify)
                    ) else { return }
                }
                guard magnificationState.isActive else { return }
                activeMagnification = ActiveMagnification(
                    amount: value.magnification,
                    anchor: value.startAnchor
                )
            }
            .onEnded { value in
                if magnificationState.isActive, session.gestureOwner == .magnify {
                    zoomState.magnify(
                        by: value.magnification,
                        at: point(for: value.startAnchor, in: viewport),
                        in: viewport,
                        contentSize: contentSize
                    )
                }
                clearMagnificationGesture()
            }
    }

    private func clearMagnificationGesture() {
        let hadOwnership = magnificationState.reset()
        activeMagnification = nil
        if hadOwnership { session.releaseGesture(.magnify) }
    }

    private func panGesture(in viewport: CGSize, contentSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .updating($activePan) { value, state, _ in
                guard session.tool == .navigate else { return }
                state = value.translation
            }
            .onEnded { value in
                guard session.tool == .navigate else { return }
                zoomState.pan(by: value.translation, in: viewport, contentSize: contentSize)
            }
    }

    private func doubleTapGesture(in viewport: CGSize, contentSize: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in
                guard session.tool == .navigate else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    zoomState.toggle(
                        at: value.location,
                        in: viewport,
                        contentSize: contentSize
                    )
                }
            }
    }

    private func displayedZoom(in viewport: CGSize, contentSize: CGSize) -> LoupeZoomState {
        var displayed = zoomState
        displayed.clamp(to: viewport, contentSize: contentSize)
        if let activeMagnification {
            displayed.magnify(
                by: activeMagnification.amount,
                at: point(for: activeMagnification.anchor, in: viewport),
                in: viewport,
                contentSize: contentSize
            )
        }
        displayed.pan(by: activePan, in: viewport, contentSize: contentSize)
        return displayed
    }

    private func point(for anchor: UnitPoint, in viewport: CGSize) -> CGPoint {
        CGPoint(x: anchor.x * viewport.width, y: anchor.y * viewport.height)
    }

    private func zoomIn(in viewport: CGSize, contentSize: CGSize) {
        let nextScale = zoomState.isFit
            ? LoupeZoomState.toggleScale
            : min(LoupeZoomState.maximumScale, zoomState.scale * 2)
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomState.zoom(
                to: nextScale,
                at: CGPoint(x: viewport.width / 2, y: viewport.height / 2),
                in: viewport,
                contentSize: contentSize
            )
        }
    }

    private func zoomOut(in viewport: CGSize, contentSize: CGSize) {
        let nextScale = zoomState.scale <= LoupeZoomState.toggleScale
            ? LoupeZoomState.fitScale
            : zoomState.scale / 2
        withAnimation(.easeInOut(duration: 0.2)) {
            zoomState.zoom(
                to: nextScale,
                at: CGPoint(x: viewport.width / 2, y: viewport.height / 2),
                in: viewport,
                contentSize: contentSize
            )
        }
    }

    // MARK: State updates

    private func handleRendered(
        _ image: CGImage,
        geometryKey: LoupeRenderedGeometryKey,
        in viewport: CGSize
    ) {
        if image.width > 0, image.height > 0 {
            let nextAspectRatio = CGFloat(image.width) / CGFloat(image.height)
            if renderedAspectFrame?.geometryKey != geometryKey
                || renderedAspectFrame?.aspectRatio != nextAspectRatio {
                renderedAspectFrame = RenderedAspectFrame(
                    geometryKey: geometryKey,
                    aspectRatio: nextAspectRatio
                )
                let contentSize = LoupeZoomState.fittedContentSize(
                    aspectRatio: nextAspectRatio,
                    in: viewport
                )
                zoomState.clamp(to: viewport, contentSize: contentSize)
            }
        }
        onRender(image)
    }

    private func resetForAsset() {
        peekTask?.cancel()
        peeking = false
        renderedAspectFrame = nil
        pointColorSamplingFrame = nil
        pointColorSamplingFailureFrame = nil
        clearMagnificationGesture()
        zoomState.reset()
    }

    private func pointColorSamplingImage(
        matching settings: DevelopSettings,
        generation: UInt64? = nil
    ) -> CGImage? {
        guard let frame = pointColorSamplingFrame,
              frame.assetID == asset.id,
              frame.settings == settings,
              frame.generation == (generation ?? session.pointColorSamplingGeneration)
        else { return nil }
        return frame.image
    }

    private func pointColorSamplingFailure(
        matching settings: DevelopSettings,
        generation: UInt64? = nil
    ) -> String? {
        guard let frame = pointColorSamplingFailureFrame,
              frame.assetID == asset.id,
              frame.settings == settings,
              frame.generation == (generation ?? session.pointColorSamplingGeneration)
        else { return nil }
        return frame.message
    }

    private func handlePressing(_ isPressing: Bool) {
        peekTask?.cancel()
        if isPressing, session.tool == .navigate, !comparing {
            peekTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled, session.tool == .navigate { peeking = true }
            }
        } else {
            peeking = false
        }
    }

    private func cancelPeek() {
        peekTask?.cancel()
        peeking = false
    }

    private func accessibilityZoomValue(_ scale: CGFloat) -> String {
        scale <= LoupeZoomState.fitScale + 0.0001
            ? "Fit to view"
            : "\(Int((scale * 100).rounded())) percent"
    }

    private var stageHelp: String {
        if session.tool == .pointColor,
           let failure = pointColorSamplingFailure(matching: asset.develop) {
            return "Point Color sampling is unavailable: \(failure)"
        }
        if session.tool == .pointColor,
           (!renderedGeometryIsCurrent
            || pointColorSamplingImage(matching: asset.develop) == nil) {
            return "Preparing the Point Color sampling image."
        }
        if session.tool.isEditing {
            return "Use the active \(session.tool.title) tool directly on the photo. Pinch to zoom."
        }
        return "Double-click or double-tap to zoom. Drag to pan while zoomed."
    }

    // MARK: Overlay

    private var samplingProgress: some View {
        Label("Preparing color sample", systemImage: "hourglass")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 12)
            .allowsHitTesting(false)
            .accessibilityLabel("Preparing Point Color sampling image")
    }

    private func samplingFailureState(_ detail: String) -> some View {
        VStack(spacing: 3) {
            Label("Color sample unavailable", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 10))
                .lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Point Color sampling unavailable")
        .accessibilityValue(detail)
    }

    private var beforeBadge: some View {
        Text("BEFORE")
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 12)
    }
}
