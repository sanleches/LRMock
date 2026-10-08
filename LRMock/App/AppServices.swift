//
//  AppServices.swift
//  RawLight
//
//  Observable dependency container injected through the SwiftUI environment.
//  Holds both imaging backends and the user's current engine choice so the app
//  can switch Core Image ↔ Metal (RawTherapee) at runtime for A/B comparison.
//
//  Views read it with `@Environment(AppServices.self)` and render through
//  `services.pipeline`; nothing else needs to know which engine is active.
//

import SwiftUI

/// The available imaging backends.
enum PipelineKind: String, CaseIterable, Identifiable, Sendable {
    case coreImage
    case metalRT

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coreImage: return "Core Image"
        case .metalRT:   return "Metal · RawTherapee"
        }
    }
}

@MainActor
@Observable
final class AppServices {

    private static let engineDefaultsKey = "rawlight.engine"

    private let coreImagePipeline = CoreImagePipeline()
    private let metalPipeline = MetalPipeline()

    /// Currently selected engine (persisted across launches).
    var engine: PipelineKind {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: Self.engineDefaultsKey) }
    }

    init() {
        let saved = UserDefaults.standard
            .string(forKey: Self.engineDefaultsKey)
            .flatMap(PipelineKind.init(rawValue:))
        self.engine = saved ?? .coreImage
    }

    /// The active backend, chosen by `engine`.
    var pipeline: RawPipeline {
        engine == .metalRT ? metalPipeline : coreImagePipeline
    }

    /// Whether the Metal backend can run (GPU + shader library present).
    var isMetalAvailable: Bool { MetalContext.shared.isAvailable }
}
