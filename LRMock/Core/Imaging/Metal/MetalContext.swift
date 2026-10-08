//
//  MetalContext.swift
//  RawLight
//
//  Shared Metal device + compute-pipeline cache for the Phase 2 GPU backend.
//
//  The heavy image math (ported from RawTherapee) runs in `.metal` compute
//  kernels. Those kernels are injected into the Core Image render graph via
//  `CIImageProcessorKernel`, so Core Image still handles decode, colour
//  management, tiling and rasterising while our shaders own the pixel ops.
//
//  Everything here is created once and is immutable/thread-safe, so the type is
//  `nonisolated` (the target defaults to `@MainActor`, which we don't want for
//  GPU work).
//

import Metal
import CoreImage

nonisolated final class MetalContext {

    static let shared = MetalContext()

    let device: MTLDevice
    /// Core Image context bound to the same device, reused by the Metal pipeline.
    let ciContext: CIContext

    private let library: MTLLibrary?
    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let cacheLock = NSLock()

    /// `true` when a usable GPU + shader library is available; the pipeline
    /// falls back to Core Image otherwise.
    let isAvailable: Bool

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            // No Metal device (shouldn't happen on modern iPads). Build a dummy
            // so the type is non-optional; `isAvailable` stays false.
            self.device = MTLCreateSystemDefaultDevice() ?? MetalContext.makeStubDevice()
            self.ciContext = CIContext()
            self.library = nil
            self.isAvailable = false
            return
        }
        self.device = device
        self.ciContext = CIContext(mtlDevice: device)
        self.library = device.makeDefaultLibrary()
        self.isAvailable = (self.library != nil)
    }

    /// Returns (and caches) the compute pipeline state for a kernel function.
    func computePipeline(function name: String) -> MTLComputePipelineState? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = pipelineCache[name] { return cached }
        guard let library, let fn = library.makeFunction(name: name) else { return nil }
        guard let state = try? device.makeComputePipelineState(function: fn) else { return nil }
        pipelineCache[name] = state
        return state
    }

    // Unreachable in practice; keeps `device` non-optional for the guard path.
    private static func makeStubDevice() -> MTLDevice {
        MTLCreateSystemDefaultDevice()!
    }
}
