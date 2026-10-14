//
//  SelectiveAdjustments.swift
//  RawLight
//
//  Pure spatial/mask math plus bounded Core Image rendering for local masks,
//  spot corrections, and manual eye corrections.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

nonisolated struct ImageCoordinateSpace: Equatable, Sendable {
    struct RasterSize: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    let extent: CGRect

    init?(extent: CGRect) {
        guard !extent.isInfinite, !extent.isNull,
              extent.minX.isFinite, extent.minY.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              extent.width >= 1, extent.height >= 1 else { return nil }
        self.extent = extent
    }

    /// Converts normalized top-left coordinates to Core Image's bottom-left
    /// coordinate system while retaining a non-zero extent origin.
    func point(_ value: NormalizedPoint) -> CGPoint {
        CGPoint(
            x: extent.minX + CGFloat(Self.unit(value.x)) * extent.width,
            y: extent.minY + CGFloat(1 - Self.unit(value.y)) * extent.height
        )
    }

    /// Vectors use normalized image axes. Positive dy points down in the
    /// persisted top-left space, and therefore points down (negative y) in CI.
    func vector(_ value: NormalizedVector) -> CGVector {
        CGVector(
            dx: CGFloat(Self.signedUnit(value.dx)) * extent.width,
            dy: -CGFloat(Self.signedUnit(value.dy)) * extent.height
        )
    }

    func longEdgeRadius(_ normalizedRadius: Double) -> CGFloat {
        CGFloat(max(0, normalizedRadius.isFinite ? normalizedRadius : 0))
            * max(extent.width, extent.height)
    }

    func rasterSize(
        maxLongEdge: Int = 2_048,
        maximumPixelCount: Int = .max
    ) -> RasterSize {
        let limit = min(2_048, max(1, maxLongEdge))
        let longest = max(extent.width, extent.height)
        let scale = min(1, CGFloat(limit) / longest)
        var width = max(1, Int(min(
            CGFloat(limit),
            (extent.width * scale).rounded(.down)
        )))
        var height = max(1, Int(min(
            CGFloat(limit),
            (extent.height * scale).rounded(.down)
        )))

        let pixelBudget = max(1, maximumPixelCount)
        if width > pixelBudget / height {
            let reduction = sqrt(Double(pixelBudget) / (Double(width) * Double(height)))
            width = max(1, Int((Double(width) * reduction).rounded(.down)))
            height = max(1, Int((Double(height) * reduction).rounded(.down)))
            while width > pixelBudget / height {
                if width >= height, width > 1 {
                    width -= 1
                } else if height > 1 {
                    height -= 1
                } else {
                    break
                }
            }
        }
        return RasterSize(width: width, height: height)
    }

    static func contains(_ point: NormalizedPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
            && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func signedUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }
}

nonisolated enum MaskMath {
    static let maximumBrushSegmentCount = 2_047
    static let maximumBrushDabCount = 65_536
    static let maximumBrushPixelVisitCount = 16_777_216

    struct BrushDabBounds: Equatable {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
        let pixelVisitCount: Int
    }

    struct BrushDabPlan: Equatable {
        let segmentCount: Int
        let candidateDabCount: Int
        let dabCount: Int
        let pixelVisitCount: Int
        let pixelVisitBudget: Int
        fileprivate let stepsPerSegment: [Int]
        fileprivate let selectedCandidateIndices: [Int]?
    }

    static func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        guard lower.isFinite, upper.isFinite, value.isFinite else { return 0 }
        guard upper > lower else { return value < lower ? 0 : 1 }
        let t = clamp((value - lower) / (upper - lower))
        return t * t * (3 - 2 * t)
    }

    /// A directional ramp: start is zero, end is one, and values beyond either
    /// endpoint remain clamped.
    static func linearAlpha(
        at point: NormalizedPoint,
        start: NormalizedPoint,
        end: NormalizedPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.000_000_000_001 else { return 0 }
        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy)
            / lengthSquared
        return smoothstep(0, 1, projection)
    }

    static func radialAlpha(
        at point: NormalizedPoint,
        center: NormalizedPoint,
        radiusX: Double,
        radiusY: Double,
        angleDegrees: Double = 0,
        feather: Double,
        inverted: Bool = false
    ) -> Double {
        let rx = max(0.000_001, finite(radiusX, fallback: 0.000_001))
        let ry = max(0.000_001, finite(radiusY, fallback: 0.000_001))
        let angle = finite(angleDegrees) * .pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let localX = cosine * dx + sine * dy
        let localY = -sine * dx + cosine * dy
        let distance = hypot(localX / rx, localY / ry)
        let feather = clamp(feather)
        let inner = max(0, 1 - feather)
        let alpha = distance <= inner ? 1 : 1 - smoothstep(inner, 1, distance)
        return invertedAlpha(alpha, inverted: inverted)
    }

    static func combine(
        _ accumulated: Double,
        with component: Double,
        operation: MaskOperation
    ) -> Double {
        let a = clamp(accumulated)
        let c = clamp(component)
        switch operation {
        case .add: return max(a, c)
        case .subtract: return a * (1 - c)
        case .intersect: return a * c
        }
    }

    static func invertedAlpha(_ alpha: Double, inverted: Bool) -> Double {
        inverted ? 1 - clamp(alpha) : clamp(alpha)
    }

    /// Plans at most one model-sized path and a fixed number of dabs. If the
    /// normal radius/4 spacing exceeds the cap, work is distributed across the
    /// whole path so every retained segment still reaches its endpoint.
    static func brushDabPlan(points: [CGPoint], radius: Double) -> BrushDabPlan? {
        guard !points.isEmpty else { return nil }
        let segmentCount = min(points.count - 1, maximumBrushSegmentCount)
        for index in 0...segmentCount {
            guard points[index].x.isFinite, points[index].y.isFinite else { return nil }
        }

        let spacing = max(0.000_001, abs(finite(radius)) / 4)
        var requestedSteps: [Int] = []
        requestedSteps.reserveCapacity(segmentCount)
        var requestedStepCount = 0
        for index in 0..<segmentCount {
            let distance = hypot(
                Double(points[index + 1].x) - Double(points[index].x),
                Double(points[index + 1].y) - Double(points[index].y)
            )
            let ratio = distance / spacing
            let steps = !ratio.isFinite || ratio >= Double(maximumBrushDabCount)
                ? maximumBrushDabCount
                : max(1, Int(ceil(ratio)))
            requestedSteps.append(steps)
            let addition = requestedStepCount.addingReportingOverflow(steps)
            guard !addition.overflow else { return nil }
            requestedStepCount = addition.partialValue
        }

        if requestedStepCount < maximumBrushDabCount {
            return BrushDabPlan(
                segmentCount: segmentCount,
                candidateDabCount: requestedStepCount + 1,
                dabCount: requestedStepCount + 1,
                pixelVisitCount: 0,
                pixelVisitBudget: .max,
                stepsPerSegment: requestedSteps,
                selectedCandidateIndices: nil
            )
        }

        let availableExtraSteps = maximumBrushDabCount - 1 - segmentCount
        let requestedExtraSteps = requestedStepCount - segmentCount
        var boundedSteps: [Int] = []
        boundedSteps.reserveCapacity(segmentCount)
        var cumulativeRequestedExtra = 0
        var allocatedExtra = 0
        for (index, steps) in requestedSteps.enumerated() {
            cumulativeRequestedExtra += steps - 1
            let targetExtra: Int
            if index == requestedSteps.count - 1 {
                targetExtra = availableExtraSteps
            } else {
                let proportional = Double(cumulativeRequestedExtra)
                    * Double(availableExtraSteps) / Double(requestedExtraSteps)
                targetExtra = max(allocatedExtra, min(
                    availableExtraSteps,
                    Int(proportional.rounded(.down))
                ))
            }
            boundedSteps.append(1 + targetExtra - allocatedExtra)
            allocatedExtra = targetExtra
        }
        return BrushDabPlan(
            segmentCount: segmentCount,
            candidateDabCount: maximumBrushDabCount,
            dabCount: maximumBrushDabCount,
            pixelVisitCount: 0,
            pixelVisitBudget: .max,
            stepsPerSegment: boundedSteps,
            selectedCandidateIndices: nil
        )
    }

    static func brushDabPlan(
        points: [CGPoint],
        radius: Double,
        width: Int,
        height: Int,
        maximumPixelVisits: Int = maximumBrushPixelVisitCount
    ) -> BrushDabPlan? {
        guard width > 0, height > 0,
              !width.multipliedReportingOverflow(by: height).overflow,
              let geometricPlan = brushDabPlan(points: points, radius: radius) else {
            return nil
        }
        let pixelVisitBudget = max(0, maximumPixelVisits)
        var candidateCosts: [Int] = []
        candidateCosts.reserveCapacity(geometricPlan.candidateDabCount)
        var totalPixelVisits = 0
        var totalOverflowed = false
        emitAllBrushDabCenters(points: points, plan: geometricPlan) { _, center in
            let cost = brushDabBounds(
                center: center,
                radius: radius,
                width: width,
                height: height
            )?.pixelVisitCount ?? 0
            candidateCosts.append(cost)
            guard !totalOverflowed else { return }
            let addition = totalPixelVisits.addingReportingOverflow(cost)
            totalOverflowed = addition.overflow
            totalPixelVisits = addition.overflow ? .max : addition.partialValue
        }
        guard candidateCosts.count == geometricPlan.candidateDabCount else { return nil }

        if !totalOverflowed, totalPixelVisits <= pixelVisitBudget {
            return BrushDabPlan(
                segmentCount: geometricPlan.segmentCount,
                candidateDabCount: geometricPlan.candidateDabCount,
                dabCount: geometricPlan.candidateDabCount,
                pixelVisitCount: totalPixelVisits,
                pixelVisitBudget: pixelVisitBudget,
                stepsPerSegment: geometricPlan.stepsPerSegment,
                selectedCandidateIndices: nil
            )
        }

        var selectedIndices: [Int] = []
        selectedIndices.reserveCapacity(geometricPlan.candidateDabCount)
        var selectedPixelVisits = 0
        for index in distributedBrushDabOrder(count: geometricPlan.candidateDabCount) {
            let cost = candidateCosts[index]
            guard cost <= pixelVisitBudget - selectedPixelVisits else { continue }
            selectedIndices.append(index)
            selectedPixelVisits += cost
        }
        selectedIndices.sort()
        return BrushDabPlan(
            segmentCount: geometricPlan.segmentCount,
            candidateDabCount: geometricPlan.candidateDabCount,
            dabCount: selectedIndices.count,
            pixelVisitCount: selectedPixelVisits,
            pixelVisitBudget: pixelVisitBudget,
            stepsPerSegment: geometricPlan.stepsPerSegment,
            selectedCandidateIndices: selectedIndices
        )
    }

    static func brushDabBounds(
        center: CGPoint,
        radius: Double,
        width: Int,
        height: Int
    ) -> BrushDabBounds? {
        guard center.x.isFinite, center.y.isFinite,
              radius.isFinite, radius >= 0, width > 0, height > 0 else { return nil }

        func clippedRange(center: Double, limit: Int) -> (minimum: Int, maximum: Int)? {
            let lower = floor(center - radius)
            let upper = ceil(center + radius)
            let last = limit - 1
            guard !lower.isNaN, !upper.isNaN,
                  upper >= 0, lower <= Double(last) else { return nil }
            let minimum = lower <= 0
                ? 0 : (lower >= Double(last) ? last : Int(lower))
            let maximum = upper >= Double(last) ? last : Int(upper)
            return minimum <= maximum ? (minimum, maximum) : nil
        }

        guard let x = clippedRange(center: Double(center.x), limit: width),
              let y = clippedRange(center: Double(center.y), limit: height) else { return nil }
        let columnDelta = x.maximum.subtractingReportingOverflow(x.minimum)
        let rowDelta = y.maximum.subtractingReportingOverflow(y.minimum)
        guard !columnDelta.overflow, !rowDelta.overflow else { return nil }
        let columnCount = columnDelta.partialValue.addingReportingOverflow(1)
        let rowCount = rowDelta.partialValue.addingReportingOverflow(1)
        guard !columnCount.overflow, !rowCount.overflow else { return nil }
        let area = columnCount.partialValue.multipliedReportingOverflow(
            by: rowCount.partialValue
        )
        guard !area.overflow else { return nil }
        return BrushDabBounds(
            minX: x.minimum,
            maxX: x.maximum,
            minY: y.minimum,
            maxY: y.maximum,
            pixelVisitCount: area.partialValue
        )
    }

    /// Streams pixel-space dabs without constructing a path-sized point array.
    @discardableResult
    static func forEachBrushDabCenter(
        points: [CGPoint],
        radius: Double,
        _ body: (CGPoint) -> Void
    ) -> BrushDabPlan? {
        guard let plan = brushDabPlan(points: points, radius: radius) else { return nil }
        emitBrushDabCenters(points: points, plan: plan, body)
        return plan
    }

    @discardableResult
    static func forEachBrushDabCenter(
        points: [CGPoint],
        radius: Double,
        width: Int,
        height: Int,
        maximumPixelVisits: Int = maximumBrushPixelVisitCount,
        _ body: (CGPoint) -> Void
    ) -> BrushDabPlan? {
        guard let plan = brushDabPlan(
            points: points,
            radius: radius,
            width: width,
            height: height,
            maximumPixelVisits: maximumPixelVisits
        ) else { return nil }
        emitBrushDabCenters(points: points, plan: plan, body)
        return plan
    }

    /// Retained for pure geometry callers; unlike the rasterizer this collects
    /// the streamed values, but the collection is always hard-capped.
    static func brushDabCenters(points: [CGPoint], radius: Double) -> [CGPoint] {
        guard let plan = brushDabPlan(points: points, radius: radius) else { return [] }
        var result: [CGPoint] = []
        result.reserveCapacity(plan.dabCount)
        emitBrushDabCenters(points: points, plan: plan) { result.append($0) }
        return result
    }

    static func brushDabAlpha(
        distance: Double,
        radius: Double,
        feather: Double,
        flow: Double,
        density: Double
    ) -> Double {
        let radius = max(0.000_001, abs(finite(radius)))
        let distance = max(0, finite(distance))
        guard distance < radius else { return 0 }
        let inner = radius * (1 - clamp(feather))
        let shape = distance <= inner ? 1 : 1 - smoothstep(inner, radius, distance)
        return clamp(shape * clamp(flow) * clamp(density))
    }

    static func accumulateBrushAlpha(
        _ existing: Double,
        dabAlpha: Double,
        erase: Bool
    ) -> Double {
        let existing = clamp(existing)
        let dab = clamp(dabAlpha)
        return erase ? existing * (1 - dab) : 1 - (1 - existing) * (1 - dab)
    }

    static func brushPathAlpha(
        at point: CGPoint,
        dabCenters: [CGPoint],
        radius: Double,
        feather: Double,
        flow: Double,
        density: Double,
        initialAlpha: Double = 0,
        erase: Bool = false
    ) -> Double {
        var accumulatedFlow = 0.0
        for center in dabCenters {
            let dab = brushDabAlpha(
                distance: hypot(Double(point.x - center.x), Double(point.y - center.y)),
                radius: radius,
                feather: feather,
                flow: flow,
                density: 1
            )
            accumulatedFlow = accumulateBrushAlpha(
                accumulatedFlow,
                dabAlpha: dab,
                erase: false
            )
        }
        return completedBrushAlpha(
            initialAlpha,
            accumulatedFlow: accumulatedFlow,
            density: density,
            erase: erase
        )
    }

    static func completedBrushAlpha(
        _ existing: Double,
        accumulatedFlow: Double,
        density: Double,
        erase: Bool
    ) -> Double {
        accumulateBrushAlpha(
            existing,
            dabAlpha: clamp(accumulatedFlow) * clamp(density),
            erase: erase
        )
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func finite(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? value : fallback
    }

    private static func emitBrushDabCenters(
        points: [CGPoint],
        plan: BrushDabPlan,
        _ body: (CGPoint) -> Void
    ) {
        guard let selectedIndices = plan.selectedCandidateIndices else {
            emitAllBrushDabCenters(points: points, plan: plan) { _, center in body(center) }
            return
        }
        var selectedOffset = 0
        emitAllBrushDabCenters(points: points, plan: plan) { candidateIndex, center in
            guard selectedOffset < selectedIndices.count,
                  selectedIndices[selectedOffset] == candidateIndex else { return }
            body(center)
            selectedOffset += 1
        }
    }

    private static func emitAllBrushDabCenters(
        points: [CGPoint],
        plan: BrushDabPlan,
        _ body: (Int, CGPoint) -> Void
    ) {
        var candidateIndex = 0
        body(candidateIndex, points[0])
        for index in 0..<plan.segmentCount {
            let start = points[index]
            let end = points[index + 1]
            let steps = plan.stepsPerSegment[index]
            for step in 1...steps {
                candidateIndex += 1
                let t = CGFloat(step) / CGFloat(steps)
                body(candidateIndex, CGPoint(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t
                ))
            }
        }
    }

    private static func distributedBrushDabOrder(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [0] }
        var result = [0, count - 1]
        var intervals = [(lower: 0, upper: count - 1)]
        var intervalOffset = 0
        while intervalOffset < intervals.count {
            let interval = intervals[intervalOffset]
            intervalOffset += 1
            guard interval.upper - interval.lower > 1 else { continue }
            let midpoint = interval.lower + (interval.upper - interval.lower) / 2
            result.append(midpoint)
            intervals.append((interval.lower, midpoint))
            intervals.append((midpoint, interval.upper))
        }
        return result
    }
}

nonisolated enum SpotMath {
    static func sourceTranslation(
        sourceOffset: NormalizedVector,
        in coordinateSpace: ImageCoordinateSpace
    ) -> CGVector {
        let sourceVector = coordinateSpace.vector(sourceOffset)
        return CGVector(dx: -sourceVector.dx, dy: -sourceVector.dy)
    }

    static func defaultSourceOffset(
        points: [NormalizedPoint],
        normalizedRadius: Double,
        in coordinateSpace: ImageCoordinateSpace
    ) -> NormalizedVector? {
        guard hasValidTargetPath(points),
              normalizedRadius.isFinite, normalizedRadius > 0 else { return nil }
        let radius = coordinateSpace.longEdgeRadius(normalizedRadius)
        let dx = min(1, Double(radius * 2.5 / coordinateSpace.extent.width))
        let dy = min(1, Double(radius * 2.5 / coordinateSpace.extent.height))
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 1
        let radiusX = Double(radius / coordinateSpace.extent.width)
        let radiusY = Double(radius / coordinateSpace.extent.height)
        let lowerX = radiusX - minX
        let upperX = 1 - radiusX - maxX
        let lowerY = radiusY - minY
        let upperY = 1 - radiusY - maxY
        guard lowerX <= upperX, lowerY <= upperY else { return nil }

        func valid(_ dx: Double, _ dy: Double) -> NormalizedVector? {
            let candidate = NormalizedVector(dx: dx, dy: dy)
            guard candidate.dx != 0 || candidate.dy != 0 else { return nil }
            return sourceSamplesAreInBounds(
                points: points,
                sourceOffset: candidate,
                normalizedRadius: normalizedRadius,
                in: coordinateSpace
            ) ? candidate : nil
        }

        let preferredCandidates = [
            (dx, 0.0), (-dx, 0.0), (0.0, dy), (0.0, -dy),
            (dx, dy), (dx, -dy), (-dx, dy), (-dx, -dy),
        ]
        for candidate in preferredCandidates {
            if let offset = valid(candidate.0, candidate.1) { return offset }
        }

        // A full 2.5-radius move does not fit. Clamp each preferred axis to its
        // feasible interval, then retain both components when an edge or corner
        // requires a shorter diagonal move.
        let midpointX = (minX + maxX) * 0.5
        let midpointY = (minY + maxY) * 0.5
        let fallbackX = min(upperX, max(lowerX, midpointX < 0.5 ? dx : -dx))
        let fallbackY = min(upperY, max(lowerY, midpointY < 0.5 ? dy : -dy))
        for candidate in [(fallbackX, 0.0), (0.0, fallbackY), (fallbackX, fallbackY)] {
            if let offset = valid(candidate.0, candidate.1) { return offset }
        }
        return nil
    }

    static func hasValidTargetPath(_ points: [NormalizedPoint]) -> Bool {
        !points.isEmpty && points.allSatisfy(ImageCoordinateSpace.contains)
    }

    static func sourceSamplesAreInBounds(
        points: [NormalizedPoint],
        sourceOffset: NormalizedVector,
        normalizedRadius: Double,
        in coordinateSpace: ImageCoordinateSpace
    ) -> Bool {
        guard hasValidTargetPath(points),
              sourceOffset.dx.isFinite, sourceOffset.dy.isFinite,
              (-1...1).contains(sourceOffset.dx), (-1...1).contains(sourceOffset.dy),
              normalizedRadius.isFinite, normalizedRadius > 0 else { return false }
        let radius = coordinateSpace.longEdgeRadius(normalizedRadius)
        let radiusX = Double(radius / coordinateSpace.extent.width)
        let radiusY = Double(radius / coordinateSpace.extent.height)
        return points.allSatisfy { point in
            let x = point.x + sourceOffset.dx
            let y = point.y + sourceOffset.dy
            return x - radiusX >= 0 && x + radiusX <= 1
                && y - radiusY >= 0 && y + radiusY <= 1
        }
    }

    static func pathAlpha(
        at point: CGPoint,
        path: [CGPoint],
        radius: Double,
        feather: Double,
        opacity: Double
    ) -> Double {
        var accumulatedFlow = 0.0
        MaskMath.forEachBrushDabCenter(points: path, radius: radius) { center in
            let dab = MaskMath.brushDabAlpha(
                distance: hypot(Double(point.x - center.x), Double(point.y - center.y)),
                radius: radius,
                feather: feather,
                flow: 1,
                density: 1
            )
            accumulatedFlow = MaskMath.accumulateBrushAlpha(
                accumulatedFlow,
                dabAlpha: dab,
                erase: false
            )
        }
        return MaskMath.completedBrushAlpha(
            0,
            accumulatedFlow: accumulatedFlow,
            density: opacity,
            erase: false
        )
    }
}

nonisolated enum RedEyeMath {
    struct Ellipse: Equatable, Sendable {
        let center: NormalizedPoint
        let radiusX: Double
        let radiusY: Double
    }

    static func redDominance(red: Double, green: Double, blue: Double) -> Double {
        let red = MaskMath.clamp(red)
        let competing = max(MaskMath.clamp(green), MaskMath.clamp(blue))
        return MaskMath.clamp((red - competing - 0.025) * 4)
    }

    static func pupilEllipse(
        for correction: RedEyeCorrection,
        in _: ImageCoordinateSpace
    ) -> Ellipse? {
        guard ImageCoordinateSpace.contains(correction.center),
              correction.radiusX.isFinite, correction.radiusY.isFinite,
              (0.000_1...0.5).contains(correction.radiusX),
              (0.000_1...0.5).contains(correction.radiusY),
              correction.pupilSize.isFinite, (0...1).contains(correction.pupilSize),
              correction.darken.isFinite, (0...1).contains(correction.darken)
        else { return nil }
        let pupilScale = 0.35 + correction.pupilSize * 0.65
        return Ellipse(
            center: correction.center,
            radiusX: correction.radiusX * pupilScale,
            radiusY: correction.radiusY * pupilScale
        )
    }

    static func catchlightEllipse(
        for correction: RedEyeCorrection,
        pupil: Ellipse,
        in coordinateSpace: ImageCoordinateSpace
    ) -> Ellipse? {
        guard correction.petEye, let offset = correction.catchlight,
              offset.dx.isFinite, offset.dy.isFinite,
              (-1...1).contains(offset.dx), (-1...1).contains(offset.dy) else { return nil }
        let x = correction.center.x + offset.dx
        let y = correction.center.y + offset.dy
        let center = NormalizedPoint(x: x, y: y)
        guard x.isFinite, y.isFinite,
              (0...1).contains(x), (0...1).contains(y),
              contains(center, in: pupil) else { return nil }

        let pixelRadius = max(0.5, min(
            pupil.radiusX * Double(coordinateSpace.extent.width),
            pupil.radiusY * Double(coordinateSpace.extent.height)
        ) * 0.14)
        return Ellipse(
            center: center,
            radiusX: pixelRadius / Double(coordinateSpace.extent.width),
            radiusY: pixelRadius / Double(coordinateSpace.extent.height)
        )
    }

    static func contains(_ point: NormalizedPoint, in ellipse: Ellipse) -> Bool {
        guard point.x.isFinite, point.y.isFinite,
              ellipse.radiusX.isFinite, ellipse.radiusY.isFinite,
              ellipse.radiusX > 0, ellipse.radiusY > 0 else { return false }
        let x = (point.x - ellipse.center.x) / ellipse.radiusX
        let y = (point.y - ellipse.center.y) / ellipse.radiusY
        return x * x + y * y <= 1
    }
}

nonisolated enum SelectiveAdjustments {
    static func applySpots(_ spots: [SpotCorrection], to input: CIImage) -> CIImage {
        guard !spots.isEmpty,
              let coordinateSpace = ImageCoordinateSpace(extent: input.extent) else { return input }
        let extent = coordinateSpace.extent
        let spots = DevelopSettings.boundedSelectivePaths(
            masks: [],
            spots: spots
        ).spots
        guard let stagePlan = MaskRasterizer.stageRasterPlan(
            workUnitCounts: Array(
                repeating: MaskRasterizer.pathMaskWorkUnitCount,
                count: spots.count
            )
        ), let pathScalarPixelBudget = stagePlan.scalarPixelBudget(
            for: MaskRasterizer.pathMaskWorkUnitCount
        ), let brushStagePlan = MaskRasterizer.stageBrushPlan(
            pathCounts: [spots.count]
        ) else { return input }
        var image = input

        for spot in spots {
            guard spot.opacity.isFinite, spot.opacity > 0, spot.opacity <= 1,
                  spot.size.isFinite, (0.001...0.25).contains(spot.size),
                  spot.feather.isFinite, (0...1).contains(spot.feather) else { continue }
            let points = Array(spot.points.prefix(SpotCorrection.maximumPointCount))
            guard SpotMath.hasValidTargetPath(points) else { continue }
            let offset: NormalizedVector?
            if let configuredOffset = spot.sourceOffset {
                offset = configuredOffset
            } else {
                offset = SpotMath.defaultSourceOffset(
                    points: points,
                    normalizedRadius: spot.size,
                    in: coordinateSpace
                )
            }
            guard let offset, SpotMath.sourceSamplesAreInBounds(
                points: points,
                sourceOffset: offset,
                normalizedRadius: spot.size,
                in: coordinateSpace
            ), let mask = MaskRasterizer.pathMask(
                points: points,
                size: spot.size,
                feather: spot.feather,
                opacity: spot.opacity,
                extent: extent,
                maximumScalarPixelWork: pathScalarPixelBudget,
                maximumBrushPixelVisits: brushStagePlan.maximumPixelVisitsPerPath
            ) else { continue }
            let translation = SpotMath.sourceTranslation(
                sourceOffset: offset,
                in: coordinateSpace
            )
            let source = image.clampedToExtent().transformed(by: CGAffineTransform(
                translationX: translation.dx,
                y: translation.dy
            )).cropped(to: extent)
            let replacement: CIImage
            switch spot.mode {
            case .clone:
                replacement = replacingRGB(
                    source,
                    preservingAlphaOf: image,
                    extent: extent
                )
            case .heal:
                // Native frequency-separation approximation: source detail is
                // carried onto the target's low-frequency tone. This is not a
                // content-aware or generative fill.
                replacement = frequencySeparatedSource(
                    source: source,
                    target: image,
                    radius: max(0.75, coordinateSpace.longEdgeRadius(spot.size) * 0.55),
                    extent: extent
                )
            case .remove:
                // The remove mode uses the same deterministic frequency split
                // with a wider low-frequency blend; it does not claim AI fill.
                replacement = frequencySeparatedSource(
                    source: source,
                    target: image,
                    radius: max(1.25, coordinateSpace.longEdgeRadius(spot.size) * 1.1),
                    extent: extent
                )
            }
            image = blend(replacement, over: image, mask: mask, extent: extent)
        }
        return image.cropped(to: extent)
    }

    static func applyRedEyes(_ corrections: [RedEyeCorrection], to input: CIImage) -> CIImage {
        guard !corrections.isEmpty,
              let coordinateSpace = ImageCoordinateSpace(extent: input.extent) else { return input }
        let extent = coordinateSpace.extent
        let corrections = Array(corrections.prefix(RedEyeCorrection.maximumCount))
        let workUnitCounts = corrections.map {
            MaskRasterizer.ellipseMaskWorkUnitCount
                * ($0.petEye && $0.catchlight != nil ? 2 : 1)
        }
        guard let stagePlan = MaskRasterizer.stageRasterPlan(
            workUnitCounts: workUnitCounts
        ), let ellipseScalarPixelBudget = stagePlan.scalarPixelBudget(
            for: MaskRasterizer.ellipseMaskWorkUnitCount
        ) else { return input }
        var image = input

        for correction in corrections {
            guard let geometry = RedEyeMath.pupilEllipse(
                for: correction,
                in: coordinateSpace
            ) else { continue }
            guard let ellipse = MaskRasterizer.ellipseMask(
                center: geometry.center,
                radiusX: geometry.radiusX,
                radiusY: geometry.radiusY,
                feather: 0.32,
                opacity: 1,
                extent: extent,
                maximumScalarPixelWork: ellipseScalarPixelBudget
            ) else { continue }

            if correction.petEye {
                let darken = 0.45 + MaskMath.clamp(correction.darken) * 0.45
                let matrix = CIFilter.colorMatrix()
                matrix.inputImage = image
                let scale = 1 - darken
                matrix.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
                matrix.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
                matrix.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
                matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
                let darkened = (matrix.outputImage ?? image).cropped(to: extent)
                image = blend(darkened, over: image, mask: ellipse, extent: extent)

                if let catchlight = RedEyeMath.catchlightEllipse(
                    for: correction,
                    pupil: geometry,
                    in: coordinateSpace
                ) {
                    if let catchlightMask = MaskRasterizer.ellipseMask(
                        center: catchlight.center,
                        radiusX: catchlight.radiusX,
                        radiusY: catchlight.radiusY,
                        feather: 0.7,
                        opacity: 0.9,
                        extent: extent,
                        maximumScalarPixelWork: ellipseScalarPixelBudget
                    ), let pupilCatchlightMask = multipliedMask(
                        catchlightMask,
                        ellipse,
                        extent: extent
                    ) {
                        let whiteRGB = CIImage(color: CIColor(
                            red: 0.95, green: 0.95, blue: 0.95, alpha: 1
                        )).cropped(to: extent)
                        let white = replacingRGB(
                            whiteRGB,
                            preservingAlphaOf: image,
                            extent: extent
                        )
                        image = blend(
                            white,
                            over: image,
                            mask: pupilCatchlightMask,
                            extent: extent
                        )
                    }
                }
            } else {
                let matrix = CIFilter.colorMatrix()
                matrix.inputImage = image
                let darken = 1 - MaskMath.clamp(correction.darken) * 0.42
                matrix.rVector = CIVector(x: 0.08 * darken,
                                          y: 0.46 * darken,
                                          z: 0.46 * darken,
                                          w: 0)
                matrix.gVector = CIVector(x: 0, y: darken, z: 0, w: 0)
                matrix.bVector = CIVector(x: 0, y: 0, z: darken, w: 0)
                matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
                let neutralized = (matrix.outputImage ?? image).cropped(to: extent)
                guard let dominance = redDominanceMask(of: image, extent: extent),
                      let gatedMask = multipliedMask(ellipse, dominance, extent: extent)
                else { continue }
                image = blend(neutralized, over: image, mask: gatedMask, extent: extent)
            }
        }
        return image.cropped(to: extent)
    }

    static func applyMasks(
        _ masks: [LocalMask],
        to input: CIImage,
        quality: PreviewRenderQuality
    ) -> CIImage {
        guard !masks.isEmpty,
              ImageCoordinateSpace(extent: input.extent) != nil else { return input }
        let extent = input.extent
        let boundedMasks = DevelopSettings.boundedSelectivePaths(
            masks: masks,
            spots: []
        ).masks
        let renderable = boundedMasks.compactMap { mask -> (
            mask: LocalMask,
            adjustment: LocalAdjustments,
            workUnitCount: Int,
            brushStrokeCount: Int
        )? in
            guard mask.enabled else { return nil }
            let adjustment = effectiveLocalAdjustments(mask.adjustments)
            guard hasVisibleAdjustment(adjustment),
                  let workUnitCount = MaskRasterizer.workUnitCount(for: mask),
                  let brushStrokeCount = MaskRasterizer.brushStrokeCount(for: mask) else {
                return nil
            }
            return (mask, adjustment, workUnitCount, brushStrokeCount)
        }
        guard let stagePlan = MaskRasterizer.stageRasterPlan(
            workUnitCounts: renderable.map { $0.workUnitCount }
        ), let brushStagePlan = MaskRasterizer.stageBrushPlan(
            pathCounts: renderable.map { $0.brushStrokeCount }
        ) else { return input }
        var image = input

        for item in renderable {
            guard let scalarPixelBudget = stagePlan.scalarPixelBudget(
                for: item.workUnitCount
             ), let alpha = MaskRasterizer.mask(
                for: item.mask,
                extent: extent,
                maximumScalarPixelWork: scalarPixelBudget,
                maximumBrushPixelVisitsPerStroke: brushStagePlan.maximumPixelVisitsPerPath
            ) else { continue }
            let adjusted = applyLocalAdjustments(
                item.adjustment,
                to: image,
                quality: quality,
                extent: extent
            )
            image = blend(adjusted, over: image, mask: alpha, extent: extent)
        }
        return image.cropped(to: extent)
    }

    static func effectiveLocalAdjustments(_ adjustment: LocalAdjustments) -> LocalAdjustments {
        let amount = adjustment.amount.isFinite
            ? min(2, max(0, adjustment.amount)) : 1
        func scaled(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(1, max(-1, value * amount))
        }

        var result = adjustment
        result.temperature = scaled(adjustment.temperature)
        result.tint = scaled(adjustment.tint)
        result.exposure = scaled(adjustment.exposure)
        result.contrast = scaled(adjustment.contrast)
        result.highlights = scaled(adjustment.highlights)
        result.shadows = scaled(adjustment.shadows)
        result.whites = scaled(adjustment.whites)
        result.blacks = scaled(adjustment.blacks)
        result.texture = scaled(adjustment.texture)
        result.clarity = scaled(adjustment.clarity)
        result.dehaze = scaled(adjustment.dehaze)
        result.hue = scaled(adjustment.hue)
        result.saturation = scaled(adjustment.saturation)
        result.sharpness = scaled(adjustment.sharpness)
        result.noiseReduction = scaled(adjustment.noiseReduction)
        result.amount = 1
        return result
    }

    private static func hasVisibleAdjustment(_ adjustment: LocalAdjustments) -> Bool {
        adjustment.temperature != 0 || adjustment.tint != 0 || adjustment.exposure != 0
            || adjustment.contrast != 0 || adjustment.highlights != 0
            || adjustment.shadows != 0 || adjustment.whites != 0 || adjustment.blacks != 0
            || adjustment.texture != 0 || adjustment.clarity != 0 || adjustment.dehaze != 0
            || adjustment.hue != 0 || adjustment.saturation != 0
            || adjustment.sharpness != 0 || adjustment.noiseReduction != 0
    }

    private static func applyLocalAdjustments(
        _ adjustment: LocalAdjustments,
        to input: CIImage,
        quality: PreviewRenderQuality,
        extent: CGRect
    ) -> CIImage {
        var image = input

        if adjustment.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(adjustment.exposure * 2.5)
            image = (filter.outputImage ?? image).cropped(to: extent)
        }

        if adjustment.temperature != 0 || adjustment.tint != 0 {
            let baseline = WhiteBalanceMapping.renderedBaseline
            let neutral = WhiteBalanceMapping.adjustedNeutral(
                baseline: baseline,
                temperature: adjustment.temperature,
                tint: adjustment.tint
            )
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: neutral.kelvin, y: neutral.tint)
            filter.targetNeutral = CIVector(x: baseline.kelvin, y: baseline.tint)
            image = (filter.outputImage ?? image).cropped(to: extent)
        }

        if adjustment.highlights != 0 || adjustment.shadows != 0
            || adjustment.whites != 0 || adjustment.blacks != 0 {
            let lut = ToneCurveLUT.channelLUT(
                master: DevelopSettings.linearCurve,
                red: DevelopSettings.linearCurve,
                green: DevelopSettings.linearCurve,
                blue: DevelopSettings.linearCurve,
                sampleCount: 256,
                highlights: adjustment.highlights,
                shadows: adjustment.shadows,
                whites: adjustment.whites,
                blacks: adjustment.blacks
            )
            let filter = CIFilter.colorCurves()
            filter.inputImage = image
            filter.curvesData = lut.withUnsafeBytes { Data($0) }
            filter.curvesDomain = CIVector(x: 0, y: 1)
            filter.colorSpace = CGColorSpaceCreateDeviceRGB()
            image = (filter.outputImage ?? image).cropped(to: extent)
        }

        if adjustment.contrast != 0 || adjustment.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = Float(1 + adjustment.contrast * 0.5)
            filter.saturation = Float(max(0, 1 + adjustment.saturation))
            filter.brightness = 0
            image = (filter.outputImage ?? image).cropped(to: extent)
        }

        if adjustment.hue != 0 {
            let filter = CIFilter.hueAdjust()
            filter.inputImage = image
            filter.angle = Float(adjustment.hue * .pi)
            image = (filter.outputImage ?? image).cropped(to: extent)
        }

        if adjustment.dehaze != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = Float(1 + adjustment.dehaze * 0.35)
            filter.saturation = Float(max(0, 1 + adjustment.dehaze * 0.25))
            filter.brightness = Float(-adjustment.dehaze * 0.03)
            image = (filter.outputImage ?? image).cropped(to: extent)
        }

        image = applyLocalPresence(
            to: image,
            amount: adjustment.clarity,
            positiveRadius: quality == .interactive ? 10 : 30,
            positiveIntensity: 0.75,
            extent: extent
        )
        image = applyLocalPresence(
            to: image,
            amount: adjustment.texture,
            positiveRadius: 2.2,
            positiveIntensity: 0.65,
            extent: extent
        )

        if adjustment.noiseReduction > 0 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            filter.noiseLevel = Float(adjustment.noiseReduction
                * (quality == .settled ? 0.05 : 0.025))
            filter.sharpness = Float(0.3 - adjustment.noiseReduction * 0.15)
            image = (filter.outputImage ?? image).cropped(to: extent)
        } else if adjustment.noiseReduction < 0 {
            image = applyUnsharp(
                to: image,
                radius: 0.8,
                intensity: -adjustment.noiseReduction * 0.35,
                extent: extent
            )
        }

        if adjustment.sharpness > 0 {
            image = applyUnsharp(
                to: image,
                radius: quality == .settled ? 1.4 : 0.9,
                intensity: adjustment.sharpness * 0.75,
                extent: extent
            )
        } else if adjustment.sharpness < 0 {
            image = softened(
                image,
                radius: -adjustment.sharpness * (quality == .settled ? 2.2 : 1.2),
                amount: -adjustment.sharpness * 0.55,
                extent: extent
            )
        }

        return image.cropped(to: extent)
    }

    private static func applyLocalPresence(
        to image: CIImage,
        amount: Double,
        positiveRadius: Double,
        positiveIntensity: Double,
        extent: CGRect
    ) -> CIImage {
        if amount > 0 {
            return applyUnsharp(
                to: image,
                radius: positiveRadius,
                intensity: amount * positiveIntensity,
                extent: extent
            )
        }
        if amount < 0 {
            return softened(
                image,
                radius: max(0.6, positiveRadius * 0.12 * -amount),
                amount: min(0.7, -amount * 0.45),
                extent: extent
            )
        }
        return image
    }

    private static func applyUnsharp(
        to image: CIImage,
        radius: Double,
        intensity: Double,
        extent: CGRect
    ) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = Float(max(0, radius))
        filter.intensity = Float(max(0, intensity))
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    private static func softened(
        _ image: CIImage,
        radius: Double,
        amount: Double,
        extent: CGRect
    ) -> CIImage {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        blur.radius = Float(max(0, radius))
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return image }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = blurred
        mix.time = Float(MaskMath.clamp(amount))
        return (mix.outputImage ?? image).cropped(to: extent)
    }

    private static func frequencySeparatedSource(
        source: CIImage,
        target: CIImage,
        radius: CGFloat,
        extent: CGRect
    ) -> CIImage {
        let sourceBlur = blurred(source, radius: radius, extent: extent)
        let targetBlur = blurred(target, radius: radius, extent: extent)
        guard let detail = arithmeticComposite(
            source,
            sourceBlur,
            k1: 0,
            k2: 1,
            k3: -1,
            k4: 0.5,
            extent: extent
        ), let combined = arithmeticComposite(
            detail,
            targetBlur,
            k1: 0,
            k2: 1,
            k3: 1,
            k4: -0.5,
            extent: extent
        ) else {
            return replacingRGB(source, preservingAlphaOf: target, extent: extent)
        }
        return replacingRGB(combined, preservingAlphaOf: target, extent: extent)
    }

    static func replacingRGB(
        _ replacement: CIImage,
        preservingAlphaOf original: CIImage,
        extent: CGRect
    ) -> CIImage {
        let filter = CIFilter.sourceInCompositing()
        filter.inputImage = opaque(replacement, extent: extent)
        filter.backgroundImage = original.cropped(to: extent)
        return (filter.outputImage ?? original).cropped(to: extent)
    }

    private static func blurred(_ image: CIImage, radius: CGFloat, extent: CGRect) -> CIImage {
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(max(0, radius))
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    private static func arithmeticComposite(
        _ input: CIImage,
        _ background: CIImage,
        k1: Double,
        k2: Double,
        k3: Double,
        k4: Double,
        extent: CGRect
    ) -> CIImage? {
        guard let filter = CIFilter(name: "CIArithmeticComposite") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(background, forKey: kCIInputBackgroundImageKey)
        filter.setValue(k1, forKey: "inputK1")
        filter.setValue(k2, forKey: "inputK2")
        filter.setValue(k3, forKey: "inputK3")
        filter.setValue(k4, forKey: "inputK4")
        return filter.outputImage?.cropped(to: extent)
    }

    private static func opaque(_ image: CIImage, extent: CGRect) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    private static func redDominanceMask(of image: CIImage, extent: CGRect) -> CIImage? {
        func channelGate(green: Double, blue: Double) -> CIImage? {
            let difference = CIFilter.colorMatrix()
            difference.inputImage = image
            let vector = CIVector(x: 4, y: green, z: blue, w: 0)
            difference.rVector = vector
            difference.gVector = vector
            difference.bVector = vector
            difference.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            difference.biasVector = CIVector(x: -0.1, y: -0.1, z: -0.1, w: 1)
            guard let raw = difference.outputImage?.cropped(to: extent) else { return nil }
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = raw
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            return clamp.outputImage?.cropped(to: extent)
        }

        // Both gates must pass, which is equivalent to requiring red to beat
        // max(green, blue). Multiplication adds a smooth photographic falloff.
        guard let overGreen = channelGate(green: -4, blue: 0),
              let overBlue = channelGate(green: 0, blue: -4)
        else { return nil }
        return multipliedMask(overGreen, overBlue, extent: extent)
    }

    private static func multipliedMask(
        _ lhs: CIImage,
        _ rhs: CIImage,
        extent: CGRect
    ) -> CIImage? {
        let filter = CIFilter.multiplyCompositing()
        filter.inputImage = lhs
        filter.backgroundImage = rhs
        return filter.outputImage?.cropped(to: extent)
    }

    private static func blend(
        _ adjusted: CIImage,
        over original: CIImage,
        mask: CIImage,
        extent: CGRect
    ) -> CIImage {
        let filter = CIFilter.blendWithMask()
        filter.inputImage = adjusted.cropped(to: extent)
        filter.backgroundImage = original.cropped(to: extent)
        filter.maskImage = mask.cropped(to: extent)
        return (filter.outputImage ?? original).cropped(to: extent)
    }
}

nonisolated enum MaskRasterizer {
    static let maximumLongEdge = 2_048
    static let maximumStageScalarPixelWork = 16_777_216
    static let maximumStageBrushPixelVisits = 16_777_216

    // One unit is one full-raster allocation or pass. These counts cover every
    // explicit scalar-array operation below; brush dab visits are budgeted separately.
    static let maskBaseWorkUnitCount = 4
    static let scalarComponentWorkUnitCount = 3
    static let brushComponentWorkUnitCount = 2
    static let brushStrokeWorkUnitCount = 2
    static let componentInversionWorkUnitCount = 1
    static let pathMaskWorkUnitCount = 5
    static let ellipseMaskWorkUnitCount = 4

    struct StageRasterPlan: Equatable {
        let workUnitCount: Int
        let maximumPixelCountPerWorkUnit: Int
        let plannedScalarPixelWork: Int

        func scalarPixelBudget(for workUnitCount: Int) -> Int? {
            guard workUnitCount > 0, workUnitCount <= self.workUnitCount else { return nil }
            let product = maximumPixelCountPerWorkUnit.multipliedReportingOverflow(
                by: workUnitCount
            )
            guard !product.overflow, product.partialValue <= plannedScalarPixelWork else {
                return nil
            }
            return product.partialValue
        }
    }

    struct StageBrushPlan: Equatable {
        let pathCount: Int
        let maximumPixelVisitsPerPath: Int
        let plannedPixelVisits: Int
    }

    struct ScalarRasterPlan: Equatable {
        let size: ImageCoordinateSpace.RasterSize
        let workUnitCount: Int
        let scalarPixelWork: Int
    }

    struct RasterPlan: Equatable {
        let size: ImageCoordinateSpace.RasterSize
        let workUnitCount: Int
        let scalarPixelWork: Int
        let brushStrokeCount: Int
        fileprivate let components: [MaskComponent]
    }

    static func stageRasterPlan(
        workUnitCounts: [Int],
        maximumScalarPixelWork: Int = maximumStageScalarPixelWork
    ) -> StageRasterPlan? {
        guard maximumScalarPixelWork > 0 else { return nil }
        var totalWorkUnitCount = 0
        for count in workUnitCounts {
            guard count >= 0 else { return nil }
            let addition = totalWorkUnitCount.addingReportingOverflow(count)
            guard !addition.overflow else { return nil }
            totalWorkUnitCount = addition.partialValue
        }
        guard totalWorkUnitCount > 0,
              totalWorkUnitCount <= maximumScalarPixelWork else { return nil }
        let maximumPixelCountPerWorkUnit = maximumScalarPixelWork / totalWorkUnitCount
        let product = maximumPixelCountPerWorkUnit.multipliedReportingOverflow(
            by: totalWorkUnitCount
        )
        guard !product.overflow else { return nil }
        return StageRasterPlan(
            workUnitCount: totalWorkUnitCount,
            maximumPixelCountPerWorkUnit: maximumPixelCountPerWorkUnit,
            plannedScalarPixelWork: product.partialValue
        )
    }

    /// Reserves one deterministic share for every path in the stage. Shares
    /// are never redistributed, so invalid paths can waste work but cannot let
    /// later paths exceed the aggregate cap.
    static func stageBrushPlan(
        pathCounts: [Int],
        maximumPixelVisits: Int = maximumStageBrushPixelVisits
    ) -> StageBrushPlan? {
        guard maximumPixelVisits >= 0 else { return nil }
        var pathCount = 0
        for count in pathCounts {
            guard count >= 0 else { return nil }
            let addition = pathCount.addingReportingOverflow(count)
            guard !addition.overflow else { return nil }
            pathCount = addition.partialValue
        }
        guard pathCount > 0 else {
            return StageBrushPlan(
                pathCount: 0,
                maximumPixelVisitsPerPath: 0,
                plannedPixelVisits: 0
            )
        }
        let maximumPixelVisitsPerPath = maximumPixelVisits / pathCount
        let product = maximumPixelVisitsPerPath.multipliedReportingOverflow(by: pathCount)
        guard !product.overflow, product.partialValue <= maximumPixelVisits else { return nil }
        return StageBrushPlan(
            pathCount: pathCount,
            maximumPixelVisitsPerPath: maximumPixelVisitsPerPath,
            plannedPixelVisits: product.partialValue
        )
    }

    static func scalarRasterPlan(
        extent: CGRect,
        workUnitCount: Int,
        maximumScalarPixelWork: Int = maximumStageScalarPixelWork
    ) -> ScalarRasterPlan? {
        guard workUnitCount > 0,
              maximumScalarPixelWork >= workUnitCount,
              let coordinateSpace = ImageCoordinateSpace(extent: extent) else { return nil }
        let pixelBudget = maximumScalarPixelWork / workUnitCount
        let size = coordinateSpace.rasterSize(
            maxLongEdge: maximumLongEdge,
            maximumPixelCount: pixelBudget
        )
        guard let count = pixelCount(size) else { return nil }
        let scalarWork = count.multipliedReportingOverflow(by: workUnitCount)
        guard !scalarWork.overflow,
              scalarWork.partialValue <= maximumScalarPixelWork else { return nil }
        return ScalarRasterPlan(
            size: size,
            workUnitCount: workUnitCount,
            scalarPixelWork: scalarWork.partialValue
        )
    }

    static func workUnitCount(for mask: LocalMask) -> Int? {
        let components = renderableComponents(mask.components)
        guard !components.isEmpty else { return nil }
        return workUnitCount(for: components)
    }

    static func brushStrokeCount(for mask: LocalMask) -> Int? {
        let components = renderableComponents(mask.components)
        guard !components.isEmpty else { return nil }
        return brushStrokeCount(for: components)
    }

    static func rasterPlan(
        for mask: LocalMask,
        extent: CGRect,
        maximumScalarPixelWork: Int = maximumStageScalarPixelWork
    ) -> RasterPlan? {
        let components = renderableComponents(mask.components)
        guard !components.isEmpty,
              let workUnitCount = workUnitCount(for: components),
              let brushStrokeCount = brushStrokeCount(for: components),
              let scalarPlan = scalarRasterPlan(
                extent: extent,
                workUnitCount: workUnitCount,
                maximumScalarPixelWork: maximumScalarPixelWork
              ) else { return nil }
        return RasterPlan(
            size: scalarPlan.size,
            workUnitCount: workUnitCount,
            scalarPixelWork: scalarPlan.scalarPixelWork,
            brushStrokeCount: brushStrokeCount,
            components: components
        )
    }

    static func mask(
        for mask: LocalMask,
        extent: CGRect,
        maximumScalarPixelWork: Int = maximumStageScalarPixelWork,
        maximumBrushPixelVisitsPerStroke: Int? = nil
    ) -> CIImage? {
        guard let plan = rasterPlan(
            for: mask,
            extent: extent,
            maximumScalarPixelWork: maximumScalarPixelWork
        ), let count = pixelCount(plan.size) else { return nil }
        let size = plan.size
        let brushPixelVisitBudget: Int
        if let maximumBrushPixelVisitsPerStroke {
            brushPixelVisitBudget = max(0, maximumBrushPixelVisitsPerStroke)
        } else {
            guard let brushPlan = stageBrushPlan(pathCounts: [plan.brushStrokeCount]) else {
                return nil
            }
            brushPixelVisitBudget = brushPlan.maximumPixelVisitsPerPath
        }
        var accumulated = [Float](repeating: 0, count: count)

        for component in plan.components {
            var alpha = componentAlpha(
                component.shape,
                size: size,
                count: count,
                maximumBrushPixelVisitsPerStroke: brushPixelVisitBudget
            )
            if component.inverted {
                for index in alpha.indices { alpha[index] = 1 - alpha[index] }
            }
            for index in accumulated.indices {
                accumulated[index] = Float(MaskMath.combine(
                    Double(accumulated[index]),
                    with: Double(alpha[index]),
                    operation: component.operation
                ))
            }
        }

        for index in accumulated.indices {
            let alpha = mask.inverted ? 1 - accumulated[index] : accumulated[index]
            accumulated[index] = Float(MaskMath.clamp(Double(alpha)))
        }
        return image(from: accumulated, size: size, extent: extent)
    }

    private static func workUnitCount(for components: [MaskComponent]) -> Int? {
        var workUnitCount = maskBaseWorkUnitCount
        for component in components {
            let componentWork: Int
            if case let .brush(strokes) = component.shape {
                let strokeWork = strokes.count.multipliedReportingOverflow(
                    by: brushStrokeWorkUnitCount
                )
                guard !strokeWork.overflow else { return nil }
                let fixedWork = brushComponentWorkUnitCount.addingReportingOverflow(
                    strokeWork.partialValue
                )
                guard !fixedWork.overflow else { return nil }
                componentWork = fixedWork.partialValue
            } else {
                componentWork = scalarComponentWorkUnitCount
            }
            let inversionWork = component.inverted ? componentInversionWorkUnitCount : 0
            let componentTotal = componentWork.addingReportingOverflow(inversionWork)
            guard !componentTotal.overflow else { return nil }
            let addition = workUnitCount.addingReportingOverflow(componentTotal.partialValue)
            guard !addition.overflow else { return nil }
            workUnitCount = addition.partialValue
        }
        return workUnitCount
    }

    private static func brushStrokeCount(for components: [MaskComponent]) -> Int? {
        var strokeCount = 0
        for component in components {
            guard case let .brush(strokes) = component.shape else { continue }
            let addition = strokeCount.addingReportingOverflow(strokes.count)
            guard !addition.overflow else { return nil }
            strokeCount = addition.partialValue
        }
        return strokeCount
    }

    static func pathMask(
        points: [NormalizedPoint],
        size normalizedSize: Double,
        feather: Double,
        opacity: Double,
        extent: CGRect,
        maximumScalarPixelWork: Int = maximumStageScalarPixelWork,
        maximumBrushPixelVisits: Int = maximumStageBrushPixelVisits
    ) -> CIImage? {
        let points = Array(points.prefix(SpotCorrection.maximumPointCount))
        guard SpotMath.hasValidTargetPath(points),
              normalizedSize.isFinite, normalizedSize > 0,
              feather.isFinite, (0...1).contains(feather),
              opacity.isFinite, (0...1).contains(opacity),
              maximumBrushPixelVisits >= 0,
              let rasterPlan = scalarRasterPlan(
                extent: extent,
                workUnitCount: pathMaskWorkUnitCount,
                maximumScalarPixelWork: maximumScalarPixelWork
              ) else { return nil }
        let size = rasterPlan.size
        guard let count = pixelCount(size) else { return nil }
        var alpha = [Float](repeating: 0, count: count)
        renderBrush(
            points: points,
            radius: normalizedSize * Double(max(size.width, size.height)),
            feather: feather,
            flow: 1,
            density: opacity,
            erase: false,
            width: size.width,
            height: size.height,
            maximumPixelVisits: maximumBrushPixelVisits,
            into: &alpha
        )
        return image(from: alpha, size: size, extent: extent)
    }

    static func ellipseMask(
        center: NormalizedPoint,
        radiusX: Double,
        radiusY: Double,
        feather: Double,
        opacity: Double,
        extent: CGRect,
        maximumScalarPixelWork: Int = maximumStageScalarPixelWork
    ) -> CIImage? {
        guard ImageCoordinateSpace.contains(center),
              radiusX.isFinite, radiusY.isFinite, radiusX > 0, radiusY > 0,
              feather.isFinite, (0...1).contains(feather),
              opacity.isFinite, (0...1).contains(opacity),
              let rasterPlan = scalarRasterPlan(
                extent: extent,
                workUnitCount: ellipseMaskWorkUnitCount,
                maximumScalarPixelWork: maximumScalarPixelWork
              ) else { return nil }
        let size = rasterPlan.size
        guard let count = pixelCount(size) else { return nil }
        var alpha = [Float](repeating: 0, count: count)
        for row in 0..<size.height {
            let y = (Double(row) + 0.5) / Double(size.height)
            for column in 0..<size.width {
                let x = (Double(column) + 0.5) / Double(size.width)
                let value = MaskMath.radialAlpha(
                    at: NormalizedPoint(x: x, y: y),
                    center: center,
                    radiusX: radiusX,
                    radiusY: radiusY,
                    feather: feather
                ) * MaskMath.clamp(opacity)
                alpha[row * size.width + column] = Float(value)
            }
        }
        return image(from: alpha, size: size, extent: extent)
    }

    private static func componentAlpha(
        _ shape: MaskShape,
        size: ImageCoordinateSpace.RasterSize,
        count: Int,
        maximumBrushPixelVisitsPerStroke: Int
    ) -> [Float] {
        var alpha = [Float](repeating: 0, count: count)
        switch shape {
        case let .linear(start, end):
            // CGImage rows are top-first, matching the persisted top-left y axis.
            for row in 0..<size.height {
                let y = (Double(row) + 0.5) / Double(size.height)
                for column in 0..<size.width {
                    let x = (Double(column) + 0.5) / Double(size.width)
                    alpha[row * size.width + column] = Float(MaskMath.linearAlpha(
                        at: NormalizedPoint(x: x, y: y),
                        start: start,
                        end: end
                    ))
                }
            }
        case let .radial(center, radiusX, radiusY, angle, feather, inverted):
            for row in 0..<size.height {
                let y = (Double(row) + 0.5) / Double(size.height)
                for column in 0..<size.width {
                    let x = (Double(column) + 0.5) / Double(size.width)
                    alpha[row * size.width + column] = Float(MaskMath.radialAlpha(
                        at: NormalizedPoint(x: x, y: y),
                        center: center,
                        radiusX: radiusX,
                        radiusY: radiusY,
                        angleDegrees: angle,
                        feather: feather,
                        inverted: inverted
                    ))
                }
            }
        case let .brush(strokes):
            for stroke in strokes.prefix(MaskShape.maximumStrokeCount) where !stroke.points.isEmpty {
                renderBrush(
                    points: Array(stroke.points.prefix(BrushStroke.maximumPointCount)),
                    radius: stroke.size * Double(max(size.width, size.height)),
                    feather: stroke.feather,
                    flow: stroke.flow,
                    density: stroke.density,
                    erase: stroke.erase,
                    width: size.width,
                    height: size.height,
                    maximumPixelVisits: maximumBrushPixelVisitsPerStroke,
                    into: &alpha
                )
            }
        }
        return alpha
    }

    private static func renderableComponents(_ components: [MaskComponent]) -> [MaskComponent] {
        components.prefix(LocalMask.maximumComponentCount).compactMap { component in
            guard case let .brush(strokes) = component.shape else { return component }
            let nonempty = strokes.prefix(MaskShape.maximumStrokeCount).filter {
                !$0.points.prefix(BrushStroke.maximumPointCount).isEmpty
            }
            guard !nonempty.isEmpty else { return nil }
            var component = component
            component.shape = .brush(strokes: Array(nonempty))
            return component
        }
    }

    private static func pixelCount(_ size: ImageCoordinateSpace.RasterSize) -> Int? {
        guard size.width > 0, size.height > 0 else { return nil }
        let product = size.width.multipliedReportingOverflow(by: size.height)
        return product.overflow ? nil : product.partialValue
    }

    private static func renderBrush(
        points: [NormalizedPoint],
        radius: Double,
        feather: Double,
        flow: Double,
        density: Double,
        erase: Bool,
        width: Int,
        height: Int,
        maximumPixelVisits: Int,
        into alpha: inout [Float]
    ) {
        guard radius.isFinite, width > 0, height > 0,
              pixelCount(ImageCoordinateSpace.RasterSize(width: width, height: height))
                == alpha.count,
              MaskMath.clamp(flow) > 0, MaskMath.clamp(density) > 0 else { return }
        let radius = min(Double(max(width, height)), max(0.5, abs(radius)))
        let path = points.prefix(MaskMath.maximumBrushSegmentCount + 1).map {
            CGPoint(
                x: MaskMath.clamp($0.x) * Double(width),
                y: MaskMath.clamp($0.y) * Double(height)
            )
        }
        var accumulatedFlow = [Float](repeating: 0, count: alpha.count)
        MaskMath.forEachBrushDabCenter(
            points: path,
            radius: radius,
            width: width,
            height: height,
            maximumPixelVisits: maximumPixelVisits
        ) { center in
            guard let bounds = MaskMath.brushDabBounds(
                center: center,
                radius: radius,
                width: width,
                height: height
            ) else { return }
            for row in bounds.minY...bounds.maxY {
                for column in bounds.minX...bounds.maxX {
                    let distance = hypot(
                        Double(column) + 0.5 - Double(center.x),
                        Double(row) + 0.5 - Double(center.y)
                    )
                    let dab = MaskMath.brushDabAlpha(
                        distance: distance,
                        radius: radius,
                        feather: feather,
                        flow: flow,
                        density: 1
                    )
                    guard dab > 0 else { continue }
                    let index = row * width + column
                    accumulatedFlow[index] = Float(MaskMath.accumulateBrushAlpha(
                        Double(accumulatedFlow[index]),
                        dabAlpha: dab,
                        erase: false
                    ))
                }
            }
        }
        for index in alpha.indices where accumulatedFlow[index] > 0 {
            alpha[index] = Float(MaskMath.completedBrushAlpha(
                Double(alpha[index]),
                accumulatedFlow: Double(accumulatedFlow[index]),
                density: density,
                erase: erase
            ))
        }
    }

    private static func image(
        from alpha: [Float],
        size: ImageCoordinateSpace.RasterSize,
        extent: CGRect
    ) -> CIImage? {
        guard pixelCount(size) == alpha.count,
              let linearGray = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: alpha.count)
        for index in alpha.indices {
            bytes[index] = UInt8((MaskMath.clamp(Double(alpha[index])) * 255).rounded())
        }
        let data = Data(
            bytesNoCopy: bytes,
            count: alpha.count,
            deallocator: .custom { _, _ in bytes.deallocate() }
        )
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: size.width,
                space: linearGray,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }
        let raster = CIImage(cgImage: cgImage)
        let transform = CGAffineTransform(
            a: extent.width / CGFloat(size.width),
            b: 0,
            c: 0,
            d: extent.height / CGFloat(size.height),
            tx: extent.minX,
            ty: extent.minY
        )
        return raster.transformed(by: transform).cropped(to: extent)
    }
}
