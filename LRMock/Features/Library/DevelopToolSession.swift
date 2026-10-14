//
//  DevelopToolSession.swift
//  RawLight
//
//  Ephemeral state shared by the loupe's direct develop tools.
//

import CoreGraphics
import Foundation
import Observation

nonisolated struct DevelopGestureArbitration: Equatable, Sendable {
    enum Owner: Equatable, Sendable {
        case edit
        case magnify
    }

    private(set) var owner: Owner?

    mutating func claim(_ candidate: Owner) -> Bool {
        guard owner == nil || owner == candidate else { return false }
        owner = candidate
        return true
    }

    mutating func release(_ candidate: Owner) {
        if owner == candidate { owner = nil }
    }

    mutating func reset() {
        owner = nil
    }
}

nonisolated struct DeferredEditGestureState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case pending
        case editing
        case blocked
    }

    enum UpdateAction: Equatable, Sendable {
        case none
        case claim
        case update
    }

    private(set) var phase: Phase = .idle

    var shouldClaimAtEnd: Bool { phase == .pending }

    mutating func update(magnifyOwnsGesture: Bool) -> UpdateAction {
        switch phase {
        case .idle:
            phase = magnifyOwnsGesture ? .blocked : .pending
            return .none
        case .pending:
            if magnifyOwnsGesture {
                phase = .blocked
                return .none
            }
            return .claim
        case .editing:
            return .update
        case .blocked:
            return .none
        }
    }

    mutating func resolveClaim(_ claimed: Bool) -> Bool {
        guard phase == .pending else { return false }
        phase = claimed ? .editing : .blocked
        return claimed
    }

    mutating func block() {
        phase = .blocked
    }

    /// Returns whether an established edit needs its record/history cleanup.
    mutating func reset() -> Bool {
        let wasEditing = phase == .editing
        phase = .idle
        return wasEditing
    }
}

nonisolated struct MagnificationGestureState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case active
        case blocked
    }

    private(set) var phase: Phase = .idle

    var needsClaim: Bool { phase == .idle }
    var isActive: Bool { phase == .active }

    mutating func resolveClaim(_ claimed: Bool) -> Bool {
        guard phase == .idle else { return phase == .active }
        phase = claimed ? .active : .blocked
        return claimed
    }

    /// Returns whether magnification ownership must be released.
    mutating func reset() -> Bool {
        let hadOwnership = phase == .active
        phase = .idle
        return hadOwnership
    }
}

nonisolated enum DevelopToolAvailability {
    static func canActivate(
        _ tool: DevelopToolSession.Tool,
        settings: DevelopSettings,
        selectedMaskID: UUID?
    ) -> Bool {
        switch tool {
        case .navigate:
            return true
        case .pointColor:
            return settings.pointColors.count < PointColorAdjustment.maximumCount
        case .brush:
            guard settings.currentPathPointCount
                    < SelectiveDevelopLimits.maximumTotalPathPoints else { return false }
            if let selectedMaskID,
               let mask = settings.masks.first(where: { $0.id == selectedMaskID }) {
                if mask.components.contains(where: { component in
                    guard case let .brush(strokes) = component.shape else { return false }
                    return strokes.count < MaskShape.maximumStrokeCount
                }) {
                    return true
                }
                if mask.components.count < LocalMask.maximumComponentCount { return true }
            }
            return settings.masks.count < LocalMask.maximumCount
        case .linearGradient, .radialGradient:
            return settings.masks.count < LocalMask.maximumCount
        case .spot:
            return settings.spots.count < SpotCorrection.maximumCount
                && settings.currentPathPointCount
                    < SelectiveDevelopLimits.maximumTotalPathPoints
        case .redEye:
            return settings.redEyes.count < RedEyeCorrection.maximumCount
        }
    }
}

@MainActor
@Observable
final class DevelopToolSession {
    enum Tool: String, CaseIterable, Equatable, Hashable, Identifiable {
        case navigate
        case pointColor
        case brush
        case linearGradient
        case radialGradient
        case spot
        case redEye

        var id: Self { self }

        var title: String {
            switch self {
            case .navigate: return "Navigate"
            case .pointColor: return "Point Color"
            case .brush: return "Brush Mask"
            case .linearGradient: return "Linear Gradient"
            case .radialGradient: return "Radial Gradient"
            case .spot: return "Spot"
            case .redEye: return "Red Eye"
            }
        }

        var icon: String {
            switch self {
            case .navigate: return "arrow.up.left.and.arrow.down.right"
            case .pointColor: return "eyedropper"
            case .brush: return "paintbrush.pointed"
            case .linearGradient: return "rectangle.split.3x1"
            case .radialGradient: return "circle.dashed"
            case .spot: return "bandage"
            case .redEye: return "eye"
            }
        }

        var isEditing: Bool { self != .navigate }
    }

    var tool: Tool = .navigate
    var selectedPointColorID: UUID?
    var selectedMaskID: UUID?
    var selectedSpotID: UUID?
    var selectedRedEyeID: UUID?
    var overlaysVisible = true
    private(set) var pointColorSamplingGeneration: UInt64 = 0

    var brushSize = 0.03
    var brushFeather = 0.5
    var brushFlow = 1.0
    var brushDensity = 1.0
    var brushErase = false

    var spotMode: SpotMode = .remove
    var spotSize = 0.02
    var spotFeather = 0.5
    var spotOpacity = 1.0

    var redEyePetMode = false
    var redEyePupilSize = 0.5
    var redEyeDarken = 0.5

    var activeGestureID: UUID?
    var activeGestureAssetID: UUID?
    var activeMaskID: UUID?
    var activeComponentID: UUID?
    var activeRecordID: UUID?
    var activePoints: [NormalizedPoint] = []
    var activePathPointCountBeforeGesture: Int?
    var activeHistoryTransaction: DevelopHistoryTransaction?
    var gestureArbitration = DevelopGestureArbitration()

    var gestureOwner: DevelopGestureArbitration.Owner? {
        gestureArbitration.owner
    }

    func activate(_ tool: Tool) {
        if tool == .pointColor { pointColorSamplingGeneration &+= 1 }
        self.tool = tool
    }

    func claimGesture(_ owner: DevelopGestureArbitration.Owner) -> Bool {
        gestureArbitration.claim(owner)
    }

    func releaseGesture(_ owner: DevelopGestureArbitration.Owner) {
        gestureArbitration.release(owner)
    }

    func clearActiveGesture() {
        activeGestureID = nil
        activeGestureAssetID = nil
        activeMaskID = nil
        activeComponentID = nil
        activeRecordID = nil
        activePoints.removeAll(keepingCapacity: true)
        activePathPointCountBeforeGesture = nil
        gestureArbitration.release(.edit)
    }

    func finish() {
        clearActiveGesture()
        gestureArbitration.reset()
        tool = .navigate
    }

    func resetForAsset() {
        pointColorSamplingGeneration &+= 1
        tool = .navigate
        selectedPointColorID = nil
        selectedMaskID = nil
        selectedSpotID = nil
        selectedRedEyeID = nil
        overlaysVisible = true

        brushSize = 0.03
        brushFeather = 0.5
        brushFlow = 1
        brushDensity = 1
        brushErase = false

        spotMode = .remove
        spotSize = 0.02
        spotFeather = 0.5
        spotOpacity = 1

        redEyePetMode = false
        redEyePupilSize = 0.5
        redEyeDarken = 0.5

        clearActiveGesture()
        activeHistoryTransaction = nil
        gestureArbitration.reset()
    }
}
