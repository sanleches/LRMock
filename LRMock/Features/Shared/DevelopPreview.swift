//
//  DevelopPreview.swift
//  RawLight
//
//  Bounded latest-wins preview rendering. One rasterization runs at a time while
//  a single pending slot is continually replaced with the newest settings. This
//  provides continuous visual feedback without building an obsolete GPU queue.
//

import SwiftUI

nonisolated enum DevelopPreviewRenderIntent: Equatable, Sendable {
    case display
    case pointColorSampling
}

nonisolated struct DevelopPreviewRequestIdentity: Equatable, Sendable {
    let assetID: UUID
    let settings: DevelopSettings
    let renderIntent: DevelopPreviewRenderIntent
    let interactivePixels: Int
    let settledPixels: Int
}

nonisolated struct DevelopPreviewFailure: Equatable, Sendable {
    let identity: DevelopPreviewRequestIdentity
    let message: String
}

struct DevelopPreviewFrame {
    let identity: DevelopPreviewRequestIdentity
    let image: CGImage
}

private nonisolated enum DevelopPreviewRequestIntent: Equatable, Sendable {
    case interactive
    case settled
    case pointColorSampling
}

actor PreviewRasterizationGate {
    static let shared = PreviewRasterizationGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var holder: UUID?
    private var waiters: [Waiter] = []
    private var queueObservers: [CheckedContinuation<Void, Never>] = []

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        try await acquire(id)
        defer { release(id) }
        try Task.checkCancellation()
        return try await operation()
    }

    func queuedRequestCount() -> Int {
        waiters.count
    }

    func waitForQueuedRequest() async {
        guard waiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            queueObservers.append(continuation)
        }
    }

    private func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        if holder == nil {
            holder = id
            return
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    waiters.append(Waiter(id: id, continuation: continuation))
                    let observers = queueObservers
                    queueObservers.removeAll()
                    for observer in observers { observer.resume() }
                }
            } onCancel: {
                Task { await self.cancelWaiting(id) }
            }
            try Task.checkCancellation()
        } catch {
            if holder == id { release(id) }
            throw error
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(_ id: UUID) {
        guard holder == id else { return }
        guard !waiters.isEmpty else {
            holder = nil
            return
        }
        let next = waiters.removeFirst()
        holder = next.id
        next.continuation.resume()
    }
}

@MainActor
@Observable
final class DevelopPreviewRenderer {
    private struct Request: Sendable {
        let identity: DevelopPreviewRequestIdentity
        let source: AssetFileAccess.Reference
        let pipeline: RawPipeline
        let generation: UInt64
        let maxPixelSize: Int
        let intent: DevelopPreviewRequestIntent

        var assetID: UUID { identity.assetID }
        var settings: DevelopSettings { identity.settings }
    }

    private(set) var renderedFrame: DevelopPreviewFrame?
    var isRendering = false
    private(set) var failure: DevelopPreviewFailure?
    private(set) var settledFrame: DevelopPreviewFrame?
    var settledVersion = 0
    var failureVersion = 0

    var rendered: CGImage? {
        guard renderedFrame?.identity == currentIdentity else { return nil }
        return renderedFrame?.image
    }
    var errorMessage: String? {
        guard failure?.identity == currentIdentity else { return nil }
        return failure?.message
    }
    var settledImage: CGImage? {
        guard settledFrame?.identity == currentIdentity else { return nil }
        return settledFrame?.image
    }
    var settledAssetID: UUID? {
        guard settledFrame?.identity == currentIdentity else { return nil }
        return settledFrame?.identity.assetID
    }
    var settledSettings: DevelopSettings? {
        guard settledFrame?.identity == currentIdentity else { return nil }
        return settledFrame?.identity.settings
    }
    var settledRenderIntent: DevelopPreviewRenderIntent? {
        guard settledFrame?.identity == currentIdentity else { return nil }
        return settledFrame?.identity.renderIntent
    }

    @ObservationIgnored private var currentIdentity: DevelopPreviewRequestIdentity?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var displayedGeneration: UInt64 = 0
    @ObservationIgnored private var pendingInteractive: Request?
    @ObservationIgnored private var pendingSettled: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var settledCache: [DevelopPreviewFrame] = []

    func submit(
        assetID: UUID,
        source: AssetFileAccess.Reference,
        settings: DevelopSettings,
        pipeline: RawPipeline,
        interactivePixels: Int,
        settledPixels: Int,
        renderIntent: DevelopPreviewRenderIntent = .display
    ) {
        let identity = DevelopPreviewRequestIdentity(
            assetID: assetID,
            settings: settings,
            renderIntent: renderIntent,
            interactivePixels: interactivePixels,
            settledPixels: settledPixels
        )
        generation &+= 1
        let requestGeneration = generation
        failure = nil
        if currentIdentity?.assetID != assetID {
            renderedFrame = nil
            settledFrame = nil
        }
        currentIdentity = identity

        settleTask?.cancel()
        pendingSettled = nil

        if let cached = settledCache.last(where: { $0.identity == identity }) {
            pendingInteractive = nil
            renderedFrame = cached
            settledFrame = cached
            displayedGeneration = requestGeneration
            settledVersion &+= 1
            isRendering = worker != nil
            return
        }

        if renderIntent == .pointColorSampling {
            pendingInteractive = nil
            pendingSettled = Request(
                identity: identity,
                source: source,
                pipeline: pipeline,
                generation: requestGeneration,
                maxPixelSize: settledPixels,
                intent: .pointColorSampling
            )
            startWorkerIfNeeded()
            return
        }

        pendingInteractive = Request(
            identity: identity,
            source: source,
            pipeline: pipeline,
            generation: requestGeneration,
            maxPixelSize: interactivePixels,
            intent: .interactive
        )
        startWorkerIfNeeded()

        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self,
                  self.generation == requestGeneration,
                  self.currentIdentity == identity
            else { return }
            self.pendingSettled = Request(
                identity: identity,
                source: source,
                pipeline: pipeline,
                generation: requestGeneration,
                maxPixelSize: settledPixels,
                intent: .settled
            )
            self.startWorkerIfNeeded()
        }
    }

    func cancel() {
        generation &+= 1
        settleTask?.cancel()
        worker?.cancel()
        settleTask = nil
        pendingInteractive = nil
        pendingSettled = nil
        // A decoder may ignore cancellation. Keep ownership until drainQueue
        // actually exits so a replacement request cannot start concurrently.
        isRendering = worker != nil
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        isRendering = true
        while !Task.isCancelled, let request = nextRequest() {
            await render(request)
        }
        isRendering = false
        worker = nil
        if pendingInteractive != nil || pendingSettled != nil {
            startWorkerIfNeeded()
        }
    }

    private func nextRequest() -> Request? {
        if let request = pendingInteractive {
            pendingInteractive = nil
            return request
        }
        if let request = pendingSettled {
            pendingSettled = nil
            return request
        }
        return nil
    }

    private func render(_ request: Request) async {
        do {
            let handle = try AssetFileAccess.open(request.source)
            defer { handle.release() }
            let fileURL = handle.url
            let result = try await PreviewRasterizationGate.shared.withPermit {
                switch request.intent {
                case .interactive, .settled:
                    try await request.pipeline.renderPreview(
                        fileURL: fileURL,
                        settings: request.settings,
                        maxPixelSize: request.maxPixelSize,
                        quality: request.intent == .interactive ? .interactive : .settled
                    )
                case .pointColorSampling:
                    try await request.pipeline.renderPointColorSamplingPreview(
                        fileURL: fileURL,
                        settings: request.settings,
                        maxPixelSize: request.maxPixelSize
                    )
                }
            }
            guard !Task.isCancelled,
                  request.assetID == currentIdentity?.assetID else { return }
            let frame = DevelopPreviewFrame(
                identity: request.identity,
                image: result.cgImage
            )

            switch request.intent {
            case .interactive:
                // Serialized completions are monotonic. Showing a just-finished
                // frame while a newer one is pending provides fluid, bounded lag.
                guard request.generation > displayedGeneration else { return }
                renderedFrame = frame
                displayedGeneration = request.generation
                if request.identity == currentIdentity { failure = nil }
            case .settled, .pointColorSampling:
                guard request.generation == generation,
                      request.identity == currentIdentity else { return }
                renderedFrame = frame
                settledFrame = frame
                displayedGeneration = request.generation
                failure = nil
                settledVersion &+= 1
                settledCache.removeAll { $0.identity == request.identity }
                settledCache.append(frame)
                if settledCache.count > 2 { settledCache.removeFirst() }
            }
        } catch is CancellationError {
            return
        } catch {
            guard request.generation == generation,
                  request.identity == currentIdentity else { return }
            if request.intent == .pointColorSampling
                || renderedFrame?.identity != request.identity {
                failure = DevelopPreviewFailure(
                    identity: request.identity,
                    message: error.localizedDescription
                )
                failureVersion &+= 1
            }
        }
    }

    func renderedImage(matching identity: DevelopPreviewRequestIdentity) -> CGImage? {
        guard renderedFrame?.identity == identity else { return nil }
        return renderedFrame?.image
    }

    func failureMessage(matching identity: DevelopPreviewRequestIdentity) -> String? {
        guard failure?.identity == identity else { return nil }
        return failure?.message
    }
}

struct DevelopPreview: View {
    let asset: ImageAsset
    let settings: DevelopSettings
    var renderIntent: DevelopPreviewRenderIntent = .display
    var onFailure: (DevelopPreviewFailure) -> Void = { _ in }
    var onRender: (CGImage) -> Void = { _ in }

    init(
        asset: ImageAsset,
        settings: DevelopSettings,
        renderIntent: DevelopPreviewRenderIntent = .display,
        onRender: @escaping (CGImage) -> Void = { _ in }
    ) {
        self.asset = asset
        self.settings = settings
        self.renderIntent = renderIntent
        self.onRender = onRender
    }

    init(
        asset: ImageAsset,
        settings: DevelopSettings,
        renderIntent: DevelopPreviewRenderIntent = .display,
        onFailure: @escaping (DevelopPreviewFailure) -> Void,
        onRender: @escaping (CGImage) -> Void
    ) {
        self.asset = asset
        self.settings = settings
        self.renderIntent = renderIntent
        self.onFailure = onFailure
        self.onRender = onRender
    }

    @Environment(AppServices.self) private var services
    @State private var renderer = DevelopPreviewRenderer()

    private let interactivePixels = 1280
    private let settledPixels = 2400

    private var requestIdentity: DevelopPreviewRequestIdentity {
        DevelopPreviewRequestIdentity(
            assetID: asset.id,
            settings: settings,
            renderIntent: renderIntent,
            interactivePixels: interactivePixels,
            settledPixels: settledPixels
        )
    }

    var body: some View {
        let identity = requestIdentity
        let rendered = renderer.renderedImage(matching: identity)
        let error = renderer.failureMessage(matching: identity)
        ZStack {
            if let rendered {
                Image(decorative: rendered, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
            } else if let error {
                missingState(error)
            } else {
                ProgressView().tint(Theme.textSecondary)
            }

            if renderer.isRendering && rendered != nil {
                ProgressView()
                    .tint(.white)
                    .padding(8)
                    .background(.black.opacity(0.4), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding()
            }
        }
        .task(id: identity) {
            renderer.submit(
                assetID: asset.id,
                source: AssetFileAccess.Reference(asset: asset),
                settings: settings,
                pipeline: services.pipeline,
                interactivePixels: interactivePixels,
                settledPixels: settledPixels,
                renderIntent: renderIntent
            )
        }
        .onChange(of: renderer.settledVersion) { _, _ in
            guard renderer.settledFrame?.identity == identity,
                  let frame = renderer.settledFrame else { return }
            onRender(frame.image)
        }
        .onChange(of: renderer.failureVersion) { _, _ in
            guard let failure = renderer.failure,
                  failure.identity == identity else { return }
            onFailure(failure)
        }
        .onDisappear { renderer.cancel() }
    }

    private func missingState(_ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Original could not be rendered")
                .font(.callout)
            Text(detail)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .foregroundStyle(Theme.textSecondary)
        .padding()
    }
}
