//
//  AppServices.swift
//  RawLight
//
//  Observable dependency container injected through the SwiftUI environment.
//  Views read it with `@Environment(AppServices.self)` and render through
//  `services.pipeline`.
//
//  The app uses a single native imaging backend (`CoreImagePipeline`) — RAW is
//  developed with Apple's GPU-accelerated `CIRAWFilter`, and the creative chain
//  is Core Image. Keeping `pipeline` behind a property means we can evolve the
//  backend later without touching any view.
//

import SwiftUI

@MainActor
@Observable
final class AppServices {
    /// The native imaging backend.
    let pipeline: RawPipeline

    init(pipeline: RawPipeline = CoreImagePipeline()) {
        self.pipeline = pipeline
    }
}
