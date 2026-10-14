//
//  DevelopToolOverlay.swift
//  RawLight
//
//  Canvas visuals and touch-first gestures for selective develop tools.
//

import CoreGraphics
import SwiftUI

/// Converts between the loupe viewport, the displayed cropped image, and the
/// transformed-but-uncropped canonical coordinate space used by the schema.
struct LoupeViewportTransform: Equatable {
    let viewportSize: CGSize
    let fittedImageRect: CGRect
    let zoomScale: CGFloat
    let zoomOffset: CGSize
    let cropRect: CGRect

    init(
        viewportSize: CGSize,
        fittedImageRect: CGRect,
        zoomScale: CGFloat = 1,
        zoomOffset: CGSize = .zero,
        cropX: Double = 0,
        cropY: Double = 0,
        cropW: Double = 1,
        cropH: Double = 1
    ) {
        self.viewportSize = viewportSize
        self.fittedImageRect = fittedImageRect
        self.zoomScale = zoomScale.isFinite && zoomScale > 0 ? zoomScale : 1
        self.zoomOffset = CGSize(
            width: zoomOffset.width.isFinite ? zoomOffset.width : 0,
            height: zoomOffset.height.isFinite ? zoomOffset.height : 0
        )

        let width = cropW.isFinite ? min(max(cropW, 0.0001), 1) : 1
        let height = cropH.isFinite ? min(max(cropH, 0.0001), 1) : 1
        let x = cropX.isFinite ? min(max(cropX, 0), 1 - width) : 0
        let y = cropY.isFinite ? min(max(cropY, 0), 1 - height) : 0
        cropRect = CGRect(
            x: CGFloat(x),
            y: CGFloat(y),
            width: CGFloat(width),
            height: CGFloat(height)
        )
    }

    var displayedImageRect: CGRect {
        let anchor = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        return CGRect(
            x: anchor.x + (fittedImageRect.minX - anchor.x) * zoomScale + zoomOffset.width,
            y: anchor.y + (fittedImageRect.minY - anchor.y) * zoomScale + zoomOffset.height,
            width: fittedImageRect.width * zoomScale,
            height: fittedImageRect.height * zoomScale
        )
    }

    func croppedNormalized(at viewportPoint: CGPoint) -> NormalizedPoint? {
        let rect = displayedImageRect
        guard rect.width > 0, rect.height > 0, rect.contains(viewportPoint) else { return nil }
        return NormalizedPoint(
            x: Double((viewportPoint.x - rect.minX) / rect.width),
            y: Double((viewportPoint.y - rect.minY) / rect.height)
        )
    }

    func canonicalNormalized(at viewportPoint: CGPoint) -> NormalizedPoint? {
        guard let cropped = croppedNormalized(at: viewportPoint) else { return nil }
        return canonicalNormalized(fromCropped: cropped)
    }

    func canonicalNormalized(fromCropped point: NormalizedPoint) -> NormalizedPoint {
        NormalizedPoint(
            x: Double(cropRect.minX) + point.x * Double(cropRect.width),
            y: Double(cropRect.minY) + point.y * Double(cropRect.height)
        )
    }

    func pointColorSourceNormalized(
        at viewportPoint: CGPoint,
        sourceImageSize: CGSize,
        settings: DevelopSettings
    ) -> NormalizedPoint? {
        guard let cropped = croppedNormalized(at: viewportPoint) else { return nil }
        return CoreImageAdjustments.pointColorSourceNormalizedPoint(
            fromTransformed: canonicalNormalized(fromCropped: cropped),
            sourceSize: sourceImageSize,
            settings: settings
        )
    }

    func visibleSpotSourceOffset(
        from point: NormalizedPoint,
        normalizedRadius: Double
    ) -> NormalizedVector? {
        let rect = displayedImageRect
        guard point.x.isFinite, point.y.isFinite,
              normalizedRadius.isFinite, normalizedRadius >= 0,
              rect.width > 0, rect.height > 0,
              cropRect.width > 0, cropRect.height > 0 else { return nil }
        let uncroppedWidth = rect.width / cropRect.width
        let uncroppedHeight = rect.height / cropRect.height
        let longEdge = max(uncroppedWidth, uncroppedHeight)
        let radiusX = CGFloat(normalizedRadius) * longEdge / uncroppedWidth
        let radiusY = CGFloat(normalizedRadius) * longEdge / uncroppedHeight
        let minimumX = cropRect.minX + radiusX
        let maximumX = cropRect.maxX - radiusX
        let minimumY = cropRect.minY + radiusY
        let maximumY = cropRect.maxY - radiusY
        guard minimumX <= maximumX, minimumY <= maximumY else { return nil }

        let proposedX = point.x < Double(cropRect.midX)
            ? point.x + Double(cropRect.width) * 0.12
            : point.x - Double(cropRect.width) * 0.12
        let proposedY = point.y < Double(cropRect.midY)
            ? point.y + Double(cropRect.height) * 0.08
            : point.y - Double(cropRect.height) * 0.08
        let sourceX = min(max(proposedX, Double(minimumX)), Double(maximumX))
        let sourceY = min(max(proposedY, Double(minimumY)), Double(maximumY))
        return NormalizedVector(dx: sourceX - point.x, dy: sourceY - point.y)
    }

    func croppedNormalized(fromCanonical point: NormalizedPoint) -> CGPoint {
        CGPoint(
            x: CGFloat((point.x - Double(cropRect.minX)) / Double(cropRect.width)),
            y: CGFloat((point.y - Double(cropRect.minY)) / Double(cropRect.height))
        )
    }

    func viewportPoint(forCropped point: NormalizedPoint) -> CGPoint {
        let rect = displayedImageRect
        return CGPoint(
            x: rect.minX + CGFloat(point.x) * rect.width,
            y: rect.minY + CGFloat(point.y) * rect.height
        )
    }

    func viewportPoint(forCanonical point: NormalizedPoint) -> CGPoint {
        viewportPoint(forCanonicalPoint: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
    }

    func viewportPoint(forCanonicalPoint point: CGPoint) -> CGPoint {
        let rect = displayedImageRect
        return CGPoint(
            x: rect.minX + ((point.x - cropRect.minX) / cropRect.width) * rect.width,
            y: rect.minY + ((point.y - cropRect.minY) / cropRect.height) * rect.height
        )
    }

    func viewportSize(forCanonicalVector vector: CGVector) -> CGSize {
        let rect = displayedImageRect
        return CGSize(
            width: abs(vector.dx / cropRect.width) * rect.width,
            height: abs(vector.dy / cropRect.height) * rect.height
        )
    }

    /// Maps a renderer radius expressed in transformed image long-edge units
    /// into the current cropped and zoomed viewport.
    func viewportRadius(forLongEdgeNormalizedRadius radius: Double) -> CGFloat {
        guard radius.isFinite else { return 0 }
        let rect = displayedImageRect
        let uncroppedWidth = rect.width / cropRect.width
        let uncroppedHeight = rect.height / cropRect.height
        return abs(CGFloat(radius)) * max(uncroppedWidth, uncroppedHeight)
    }
}

nonisolated enum PointColorImageSampler {
    private static let minimumUsableAlpha: Float = 1 / 255

    /// Converts through the image's embedded profile into the app's explicit
    /// Point Color domain: extended-linear Display P3.
    static func extendedLinearDisplayP3(
        in image: CGImage,
        at point: NormalizedPoint
    ) -> SIMD3<Double>? {
        guard image.width > 0, image.height > 0, image.colorSpace != nil,
              point.x.isFinite, point.y.isFinite,
              let linearDisplayP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        else { return nil }

        let normalizedX = min(1, max(0, point.x))
        let normalizedY = min(1, max(0, point.y))
        let x = min(image.width - 1, Int((normalizedX * Double(image.width)).rounded(.down)))
        let y = min(image.height - 1, Int((normalizedY * Double(image.height)).rounded(.down)))
        guard let sample = image.cropping(
            to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
        ) else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.floatComponents)
            .union(.byteOrder32Little)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 32,
            bytesPerRow: MemoryLayout<Float>.size * pixel.count,
            space: linearDisplayP3,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let alpha = pixel[3]
        guard alpha.isFinite, alpha > minimumUsableAlpha else { return nil }
        let rgb = SIMD3(pixel[0], pixel[1], pixel[2]) / alpha
        guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite,
              (0...1).contains(rgb.x),
              (0...1).contains(rgb.y),
              (0...1).contains(rgb.z)
        else { return nil }
        return SIMD3(Double(rgb.x), Double(rgb.y), Double(rgb.z))
    }
}

enum PointColorPresentation {
    static func swatch(_ adjustment: PointColorAdjustment) -> Color {
        let rgb = ColorCubeEngine.pointColorLinearDisplayP3(
            luminance: adjustment.luminance,
            chroma: adjustment.chroma,
            hue: adjustment.hue
        )
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let color = CGColor(
                colorSpace: colorSpace,
                components: [CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 1]
              ) else { return .gray }
        return Color(cgColor: color)
    }
}

struct DevelopToolOverlay: View {
    @Bindable var asset: ImageAsset
    @Bindable var session: DevelopToolSession
    let history: DevelopHistoryCoordinator
    let pointColorSamplingImage: CGImage?
    let transform: LoupeViewportTransform
    let enabled: Bool

    @State private var editDragState = DeferredEditGestureState()
    @GestureState private var editDragActive = false

    var body: some View {
        Canvas { context, _ in
            guard session.overlaysVisible else { return }
            context.clip(to: Path(transform.displayedImageRect))
            drawPointColors(in: &context)
            drawMasks(in: &context)
            drawSpots(in: &context)
            drawRedEyes(in: &context)
        }
        .contentShape(Rectangle())
        .gesture(editDrag)
        .simultaneousGesture(editTap)
        .allowsHitTesting(enabled && session.tool.isEditing)
        .accessibilityLabel("\(session.tool.title) editing canvas")
        .accessibilityHint("Draw or tap directly on the photo")
        .accessibilityChildren {
            ForEach(asset.develop.pointColors) { pointColor in
                Text("Point color")
                    .accessibilityAddTraits(
                        session.selectedPointColorID == pointColor.id ? .isSelected : []
                    )
            }
            ForEach(asset.develop.masks) { mask in
                Text(mask.name.isEmpty ? "Mask" : mask.name)
                    .accessibilityAddTraits(session.selectedMaskID == mask.id ? .isSelected : [])
            }
            ForEach(asset.develop.spots) { spot in
                Text("\(spotModeName(spot.mode)) spot")
                    .accessibilityAddTraits(session.selectedSpotID == spot.id ? .isSelected : [])
            }
            ForEach(asset.develop.redEyes) { correction in
                Text(correction.petEye ? "Pet eye correction" : "Red eye correction")
                    .accessibilityAddTraits(
                        session.selectedRedEyeID == correction.id ? .isSelected : []
                    )
            }
        }
        .onChange(of: enabled) { _, isEnabled in
            if !isEnabled { cancelEditDrag() }
        }
        .onChange(of: session.tool) { _, _ in
            cancelEditDrag()
        }
        .onChange(of: editDragActive) { wasActive, isActive in
            if wasActive, !isActive { cancelEditDrag() }
        }
        .onDisappear { cancelEditDrag() }
    }

    private var editTap: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                guard enabled, session.claimGesture(.edit) else { return }
                defer { session.releaseGesture(.edit) }
                switch session.tool {
                case .pointColor:
                    samplePointColor(at: value.location)
                case .spot:
                    createSpot(at: value.location)
                default:
                    break
                }
            }
    }

    private var editDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .updating($editDragActive) { _, isActive, _ in
                isActive = true
            }
            .onChanged { value in
                guard enabled else { return }
                switch editDragState.update(
                    magnifyOwnsGesture: session.gestureOwner == .magnify
                ) {
                case .none:
                    return
                case .claim:
                    guard editDragState.resolveClaim(session.claimGesture(.edit)) else { return }
                case .update:
                    break
                }
                updateEditDrag(value)
            }
            .onEnded { value in
                if editDragState.shouldClaimAtEnd,
                   editDragState.resolveClaim(session.claimGesture(.edit)) {
                    updateEditDrag(value)
                }
                if editDragState.reset() { finishGesture() }
            }
    }

    private func cancelEditDrag() {
        if editDragState.reset() { finishGesture() }
    }

    private func updateEditDrag(_ value: DragGesture.Value) {
        switch session.tool {
        case .brush:
            updateBrush(value)
        case .linearGradient:
            updateLinearGradient(value)
        case .radialGradient:
            updateRadialGradient(value)
        case .redEye:
            updateRedEye(value)
        default:
            break
        }
        updateCanvasHistory()
    }

    // MARK: Gestures

    private func updateBrush(_ value: DragGesture.Value) {
        guard let point = transform.canonicalNormalized(at: value.location) else { return }

        if session.activeGestureID == nil {
            let start = transform.canonicalNormalized(at: value.startLocation) ?? point
            let initialPoints = shouldAppend(point, after: start) ? [start, point] : [point]
            guard beginCanvasHistory() else { return }
            guard let destination = brushDestination(startingWith: initialPoints) else {
                cancelCanvasHistory()
                session.releaseGesture(.edit)
                editDragState.block()
                return
            }
            session.activeGestureID = UUID()
            session.activeGestureAssetID = asset.id
            session.activeMaskID = destination.maskID
            session.activeComponentID = destination.componentID
            session.activePoints = destination.points
            session.activePathPointCountBeforeGesture = destination.pathPointCountBefore
            session.selectedMaskID = destination.maskID
            return
        }

        guard session.activeGestureAssetID == asset.id,
              let maskID = session.activeMaskID,
              let componentID = session.activeComponentID,
              let last = session.activePoints.last,
              shouldAppend(point, after: last),
              session.activePoints.count < BrushStroke.maximumPointCount else { return }

        let pathPointCount = (session.activePathPointCountBeforeGesture ?? 0)
            + session.activePoints.count
        var settings = asset.develop
        guard pathPointCount < SelectiveDevelopLimits.maximumTotalPathPoints,
              let maskIndex = settings.masks.firstIndex(where: { $0.id == maskID }),
              let componentIndex = settings.masks[maskIndex].components.firstIndex(
                where: { $0.id == componentID }
              ),
              case var .brush(strokes) = settings.masks[maskIndex]
                .components[componentIndex].shape,
              !strokes.isEmpty,
              strokes[strokes.count - 1].points.count < BrushStroke.maximumPointCount
        else { return }

        strokes[strokes.count - 1].points.append(point)
        settings.masks[maskIndex].components[componentIndex].shape = .brush(strokes: strokes)
        asset.develop = settings
        session.activePoints.append(point)
    }

    private func brushDestination(
        startingWith proposedPoints: [NormalizedPoint]
    ) -> (
        maskID: UUID,
        componentID: UUID,
        points: [NormalizedPoint],
        pathPointCountBefore: Int
    )? {
        var settings = asset.develop
        let pathPointCountBefore = settings.currentPathPointCount
        let remaining = SelectiveDevelopLimits.maximumTotalPathPoints - pathPointCountBefore
        let pointLimit = min(BrushStroke.maximumPointCount, max(0, remaining))
        let points = Array(proposedPoints.prefix(pointLimit))
        guard !points.isEmpty else { return nil }

        let stroke = BrushStroke(
            points: points,
            size: session.brushSize,
            feather: session.brushFeather,
            flow: session.brushFlow,
            density: session.brushDensity,
            erase: session.brushErase
        )

        if let maskID = session.selectedMaskID,
           let maskIndex = settings.masks.firstIndex(where: { $0.id == maskID }) {
            var mask = settings.masks[maskIndex]
            if let componentIndex = mask.components.lastIndex(where: { component in
                guard case let .brush(strokes) = component.shape else { return false }
                return strokes.count < MaskShape.maximumStrokeCount
            }), case var .brush(strokes) = mask.components[componentIndex].shape {
                strokes.append(stroke)
                mask.components[componentIndex].shape = .brush(strokes: strokes)
                let componentID = mask.components[componentIndex].id
                settings.masks[maskIndex] = mask
                asset.develop = settings
                return (maskID, componentID, points, pathPointCountBefore)
            }

            if mask.components.count < LocalMask.maximumComponentCount {
                let component = MaskComponent(shape: .brush(strokes: [stroke]))
                mask.components.append(component)
                settings.masks[maskIndex] = mask
                asset.develop = settings
                return (maskID, component.id, points, pathPointCountBefore)
            }
        }

        guard settings.masks.count < LocalMask.maximumCount else { return nil }
        let component = MaskComponent(shape: .brush(strokes: [stroke]))
        let mask = LocalMask(
            name: nextMaskName("Brush"),
            components: [component]
        )
        settings.masks.append(mask)
        asset.develop = settings
        return (mask.id, component.id, points, pathPointCountBefore)
    }

    private func updateLinearGradient(_ value: DragGesture.Value) {
        guard let start = transform.canonicalNormalized(at: value.startLocation),
              let end = transform.canonicalNormalized(at: value.location) else { return }

        if session.activeGestureID == nil {
            guard asset.develop.masks.count < LocalMask.maximumCount else { return }
            guard beginCanvasHistory() else { return }
            let component = MaskComponent(shape: .linear(start: start, end: end))
            let mask = LocalMask(name: nextMaskName("Linear"), components: [component])
            guard appendMask(mask) else {
                cancelCanvasHistory()
                session.releaseGesture(.edit)
                editDragState.block()
                return
            }
            session.activeGestureID = UUID()
            session.activeGestureAssetID = asset.id
            session.activeMaskID = mask.id
            session.activeComponentID = component.id
            session.selectedMaskID = mask.id
            return
        }

        guard session.activeGestureAssetID == asset.id,
              let maskID = session.activeMaskID,
              let componentID = session.activeComponentID else { return }
        updateMask(id: maskID) { mask in
            guard let index = mask.components.firstIndex(where: { $0.id == componentID }) else { return }
            mask.components[index].shape = .linear(start: start, end: end)
        }
    }

    private func updateRadialGradient(_ value: DragGesture.Value) {
        guard let center = transform.canonicalNormalized(at: value.startLocation),
              let edge = transform.canonicalNormalized(at: value.location) else { return }
        let radiusX = max(0.0001, abs(edge.x - center.x))
        let radiusY = max(0.0001, abs(edge.y - center.y))

        if session.activeGestureID == nil {
            guard asset.develop.masks.count < LocalMask.maximumCount else { return }
            guard beginCanvasHistory() else { return }
            let component = MaskComponent(shape: .radial(
                center: center,
                radiusX: radiusX,
                radiusY: radiusY,
                angle: 0,
                feather: session.brushFeather,
                inverted: false
            ))
            let mask = LocalMask(name: nextMaskName("Radial"), components: [component])
            guard appendMask(mask) else {
                cancelCanvasHistory()
                session.releaseGesture(.edit)
                editDragState.block()
                return
            }
            session.activeGestureID = UUID()
            session.activeGestureAssetID = asset.id
            session.activeMaskID = mask.id
            session.activeComponentID = component.id
            session.selectedMaskID = mask.id
            return
        }

        guard session.activeGestureAssetID == asset.id,
              let maskID = session.activeMaskID,
              let componentID = session.activeComponentID else { return }
        updateMask(id: maskID) { mask in
            guard let index = mask.components.firstIndex(where: { $0.id == componentID }),
                  case let .radial(_, _, _, angle, feather, inverted) = mask.components[index].shape
            else { return }
            mask.components[index].shape = .radial(
                center: center,
                radiusX: radiusX,
                radiusY: radiusY,
                angle: angle,
                feather: feather,
                inverted: inverted
            )
        }
    }

    private func updateRedEye(_ value: DragGesture.Value) {
        guard let center = transform.canonicalNormalized(at: value.startLocation),
              let edge = transform.canonicalNormalized(at: value.location) else { return }
        let radiusX = max(0.0001, abs(edge.x - center.x))
        let radiusY = max(0.0001, abs(edge.y - center.y))

        if session.activeGestureID == nil {
            guard asset.develop.redEyes.count < RedEyeCorrection.maximumCount,
                  beginCanvasHistory() else { return }
            let correction = RedEyeCorrection(
                center: center,
                radiusX: radiusX,
                radiusY: radiusY,
                pupilSize: session.redEyePupilSize,
                darken: session.redEyeDarken,
                petEye: session.redEyePetMode
            )
            var settings = asset.develop
            settings.redEyes.append(correction)
            asset.develop = settings
            session.activeGestureID = UUID()
            session.activeGestureAssetID = asset.id
            session.activeRecordID = correction.id
            session.selectedRedEyeID = correction.id
            return
        }

        guard session.activeGestureAssetID == asset.id,
              let correctionID = session.activeRecordID else { return }
        updateRedEye(id: correctionID) { correction in
            correction.center = center
            correction.radiusX = min(radiusX, 0.5)
            correction.radiusY = min(radiusY, 0.5)
        }
    }

    private func samplePointColor(at viewportPoint: CGPoint) {
        guard asset.develop.pointColors.count < PointColorAdjustment.maximumCount,
              let image = pointColorSamplingImage,
              let cropped = transform.croppedNormalized(at: viewportPoint),
              let source = transform.pointColorSourceNormalized(
                at: viewportPoint,
                sourceImageSize: CGSize(
                    width: CGFloat(image.width),
                    height: CGFloat(image.height)
                ),
                settings: asset.develop
              ),
              let rgb = PointColorImageSampler.extendedLinearDisplayP3(
                in: image,
                at: source
              )
        else { return }

        let canonical = transform.canonicalNormalized(fromCropped: cropped)
        let adjustment = pointColor(from: rgb, location: canonical)
        let before = asset.develop
        guard let transaction = history.beginChange(for: asset.id, current: before) else { return }
        var settings = before
        settings.pointColors.append(adjustment)
        asset.develop = settings
        history.updateChange(transaction, current: settings)
        history.endChange(transaction)
        session.selectedPointColorID = adjustment.id
        session.finish()
    }

    private func createSpot(at viewportPoint: CGPoint) {
        guard asset.develop.spots.count < SpotCorrection.maximumCount,
              asset.develop.currentPathPointCount
                < SelectiveDevelopLimits.maximumTotalPathPoints,
              let point = transform.canonicalNormalized(at: viewportPoint) else { return }
        let before = asset.develop
        guard let transaction = history.beginChange(for: asset.id, current: before) else { return }
        var settings = before
        let source = transform.visibleSpotSourceOffset(
            from: point,
            normalizedRadius: session.spotSize
        )
        let correction = SpotCorrection(
            mode: session.spotMode,
            points: [point],
            size: session.spotSize,
            feather: session.spotFeather,
            opacity: session.spotOpacity,
            sourceOffset: source
        )
        settings.spots.append(correction)
        asset.develop = settings
        history.updateChange(transaction, current: settings)
        history.endChange(transaction)
        session.selectedSpotID = correction.id
        if !DevelopToolAvailability.canActivate(
            .spot,
            settings: settings,
            selectedMaskID: session.selectedMaskID
        ) {
            session.finish()
        }
    }

    private func finishGesture() {
        let hadActiveGesture = session.activeGestureID != nil
        finishCanvasHistory()
        session.clearActiveGesture()
        guard hadActiveGesture else { return }
        if !DevelopToolAvailability.canActivate(
            session.tool,
            settings: asset.develop,
            selectedMaskID: session.selectedMaskID
        ) {
            session.finish()
        }
    }

    private func beginCanvasHistory() -> Bool {
        if session.activeHistoryTransaction != nil { return true }
        guard let transaction = history.beginChange(
            for: asset.id,
            current: asset.develop
        ) else {
            session.releaseGesture(.edit)
            editDragState.block()
            return false
        }
        session.activeHistoryTransaction = transaction
        return true
    }

    private func updateCanvasHistory() {
        guard let transaction = session.activeHistoryTransaction else { return }
        history.updateChange(transaction, current: asset.develop)
    }

    private func finishCanvasHistory() {
        guard let transaction = session.activeHistoryTransaction else { return }
        session.activeHistoryTransaction = nil
        history.endChange(transaction, current: asset.develop)
    }

    private func cancelCanvasHistory() {
        guard let transaction = session.activeHistoryTransaction else { return }
        session.activeHistoryTransaction = nil
        history.cancelChange(transaction)
    }

    // MARK: Drawing

    private func drawPointColors(in context: inout GraphicsContext) {
        for adjustment in asset.develop.pointColors {
            guard let point = adjustment.location else { continue }
            let center = transform.viewportPoint(forCanonical: point)
            let selected = session.selectedPointColorID == adjustment.id
            let radius: CGFloat = selected ? 8 : 6
            let outer = Path(ellipseIn: CGRect(
                x: center.x - radius - 2,
                y: center.y - radius - 2,
                width: (radius + 2) * 2,
                height: (radius + 2) * 2
            ))
            context.fill(outer, with: .color(.black.opacity(0.85)))
            let inner = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.fill(inner, with: .color(PointColorPresentation.swatch(adjustment)))
            context.stroke(inner, with: .color(.white), lineWidth: selected ? 2 : 1)
        }
    }

    private func drawMasks(in context: inout GraphicsContext) {
        for mask in asset.develop.masks {
            let selected = session.selectedMaskID == mask.id
            let color: Color = mask.enabled ? (selected ? .yellow : .cyan) : .gray
            for component in mask.components {
                switch component.shape {
                case let .brush(strokes):
                    for stroke in strokes {
                        guard let first = stroke.points.first else { continue }
                        var path = Path()
                        path.move(to: transform.viewportPoint(forCanonical: first))
                        for point in stroke.points.dropFirst() {
                            path.addLine(to: transform.viewportPoint(forCanonical: point))
                        }
                        let width = transform.viewportRadius(
                            forLongEdgeNormalizedRadius: stroke.size
                        ) * 2
                        context.stroke(path, with: .color(.black.opacity(0.8)),
                                       style: StrokeStyle(lineWidth: width + 3, lineCap: .round, lineJoin: .round))
                        context.stroke(path, with: .color(color.opacity(stroke.erase ? 0.65 : 0.9)),
                                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                                                          dash: stroke.erase ? [6, 4] : []))
                    }
                case let .linear(start, end):
                    let startPoint = transform.viewportPoint(forCanonical: start)
                    let endPoint = transform.viewportPoint(forCanonical: end)
                    var path = Path()
                    path.move(to: startPoint)
                    path.addLine(to: endPoint)
                    strokeHighContrast(path, color: color, in: &context)
                    drawHandle(at: startPoint, color: color, selected: selected, in: &context)
                    drawHandle(at: endPoint, color: color, selected: selected, in: &context)
                case let .radial(center, radiusX, radiusY, angle, _, inverted):
                    let path = radialPath(
                        center: center,
                        radiusX: radiusX,
                        radiusY: radiusY,
                        angle: angle
                    )
                    strokeHighContrast(path, color: color, dashed: inverted, in: &context)
                    drawHandle(
                        at: transform.viewportPoint(forCanonical: center),
                        color: color,
                        selected: selected,
                        in: &context
                    )
                }
            }
        }
    }

    private func drawSpots(in context: inout GraphicsContext) {
        for spot in asset.develop.spots {
            guard let target = spot.points.first else { continue }
            let targetPoint = transform.viewportPoint(forCanonical: target)
            let radius = spotRadius(spot.size)
            let selected = session.selectedSpotID == spot.id
            let color: Color = selected ? .yellow : .white
            drawCircle(center: targetPoint, radius: radius, color: color, dashed: false, in: &context)

            if let offset = spot.sourceOffset {
                let source = CGPoint(
                    x: CGFloat(target.x + offset.dx),
                    y: CGFloat(target.y + offset.dy)
                )
                let sourcePoint = transform.viewportPoint(forCanonicalPoint: source)
                var connector = Path()
                connector.move(to: targetPoint)
                connector.addLine(to: sourcePoint)
                strokeHighContrast(connector, color: color.opacity(0.75), in: &context)
                drawCircle(center: sourcePoint, radius: radius, color: color, dashed: true, in: &context)
            }
        }
    }

    private func drawRedEyes(in context: inout GraphicsContext) {
        for correction in asset.develop.redEyes {
            let selected = session.selectedRedEyeID == correction.id
            let color: Color = correction.petEye ? .green : (selected ? .yellow : .red)
            let path = radialPath(
                center: correction.center,
                radiusX: correction.radiusX,
                radiusY: correction.radiusY,
                angle: 0
            )
            strokeHighContrast(path, color: color, in: &context)
            if selected {
                drawHandle(
                    at: transform.viewportPoint(forCanonical: correction.center),
                    color: color,
                    selected: true,
                    in: &context
                )
            }
        }
    }

    private func radialPath(
        center: NormalizedPoint,
        radiusX: Double,
        radiusY: Double,
        angle: Double
    ) -> Path {
        var path = Path()
        let radians = angle * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        for index in 0...64 {
            let theta = Double(index) / 64 * 2 * .pi
            let x = cos(theta) * radiusX
            let y = sin(theta) * radiusY
            let point = CGPoint(
                x: CGFloat(center.x + x * cosine - y * sine),
                y: CGFloat(center.y + x * sine + y * cosine)
            )
            let viewportPoint = transform.viewportPoint(forCanonicalPoint: point)
            if index == 0 { path.move(to: viewportPoint) } else { path.addLine(to: viewportPoint) }
        }
        path.closeSubpath()
        return path
    }

    private func strokeHighContrast(
        _ path: Path,
        color: Color,
        dashed: Bool = false,
        in context: inout GraphicsContext
    ) {
        let dash: [CGFloat] = dashed ? [6, 4] : []
        context.stroke(path, with: .color(.black.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round, dash: dash))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash))
    }

    private func drawHandle(
        at center: CGPoint,
        color: Color,
        selected: Bool,
        in context: inout GraphicsContext
    ) {
        let radius: CGFloat = selected ? 7 : 6
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(.black.opacity(0.85)))
        context.fill(Path(ellipseIn: rect), with: .color(color))
        context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1)
    }

    private func drawCircle(
        center: CGPoint,
        radius: CGFloat,
        color: Color,
        dashed: Bool,
        in context: inout GraphicsContext
    ) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        let path = Path(ellipseIn: rect)
        let dash: [CGFloat] = dashed ? [5, 4] : []
        context.stroke(path, with: .color(.black.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 5, dash: dash))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 2, dash: dash))
    }

    // MARK: Model helpers

    @discardableResult
    private func appendMask(_ mask: LocalMask) -> Bool {
        var settings = asset.develop
        guard settings.masks.count < LocalMask.maximumCount else { return false }
        settings.masks.append(mask)
        asset.develop = settings
        return true
    }

    private func updateMask(id: UUID, change: (inout LocalMask) -> Void) {
        var settings = asset.develop
        guard let index = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.masks[index])
        asset.develop = settings
    }

    private func updateRedEye(id: UUID, change: (inout RedEyeCorrection) -> Void) {
        var settings = asset.develop
        guard let index = settings.redEyes.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.redEyes[index])
        asset.develop = settings
    }

    private func nextMaskName(_ base: String) -> String {
        "\(base) \(asset.develop.masks.count + 1)"
    }

    private func shouldAppend(_ point: NormalizedPoint, after previous: NormalizedPoint) -> Bool {
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        let threshold = max(0.0015, session.brushSize * 0.08)
        return dx * dx + dy * dy >= threshold * threshold
    }

    private func spotRadius(_ size: Double) -> CGFloat {
        transform.viewportRadius(forLongEdgeNormalizedRadius: size)
    }

    private func spotModeName(_ mode: SpotMode) -> String {
        switch mode {
        case .remove: return "Remove"
        case .heal: return "Heal"
        case .clone: return "Clone"
        }
    }

    // MARK: Point color sampling

    private func pointColor(
        from rgb: SIMD3<Double>,
        location: NormalizedPoint
    ) -> PointColorAdjustment {
        let reference = ColorCubeEngine.pointColorReference(
            red: rgb.x,
            green: rgb.y,
            blue: rgb.z
        )
        return PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: reference.hue,
            location: location
        )
    }

}
