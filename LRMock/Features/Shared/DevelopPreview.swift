//
//  DevelopPreview.swift
//  RawLight
//
//  Bounded latest-wins preview rendering. One rasterization runs at a time while
//  a single pending slot is continually replaced with the newest settings. This
//  provides continuous visual feedback without building an obsolete GPU queue.
//

import SwiftUI

private struct PreviewTaskID: Equatable {
    let assetID: UUID
    let settings: DevelopSettings
}

@MainActor
@Observable
final class DevelopPreviewRenderer {
    private enum Intent { case interactive, settled }

    private struct Request {
        let assetID: UUID
        let source: AssetFileAccess.Reference
        let settings: DevelopSettings
        let pipeline: RawPipeline
        let generation: UInt64
        let maxPixelSize: Int
        let intent: Intent
    }

    private struct CachedRender {
        let assetID: UUID
        let settings: DevelopSettings
        let image: CGImage
    }

    var rendered: CGImage?
    var isRendering = false
    var errorMessage: String?
    var settledImage: CGImage?
    var settledVersion = 0

    @ObservationIgnored private var currentAssetID: UUID?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var displayedGeneration: UInt64 = 0
    @ObservationIgnored private var pendingInteractive: Request?
    @ObservationIgnored private var pendingSettled: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var settledCache: [CachedRender] = []

    func submit(
        assetID: UUID,
        source: AssetFileAccess.Reference,
        settings: DevelopSettings,
        pipeline: RawPipeline,
        interactivePixels: Int,
        settledPixels: Int
    ) {
        generation &+= 1
        let requestGeneration = generation
        if currentAssetID != assetID {
            currentAssetID = assetID
            rendered = nil
            settledImage = nil
            errorMessage = nil
        }

        settleTask?.cancel()
        pendingSettled = nil

        if let cached = settledCache.last(where: {
            $0.assetID == assetID && $0.settings == settings
        }) {
            pendingInteractive = nil
            rendered = cached.image
            settledImage = cached.image
            displayedGeneration = requestGeneration
            settledVersion &+= 1
            isRendering = worker != nil
            return
        }

        pendingInteractive = Request(
            assetID: assetID,
            source: source,
            settings: settings,
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
                  self.currentAssetID == assetID
            else { return }
            self.pendingSettled = Request(
                assetID: assetID,
                source: source,
                settings: settings,
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
        worker = nil
        pendingInteractive = nil
        pendingSettled = nil
        isRendering = false
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
            let result = try await request.pipeline.renderPreview(
                fileURL: handle.url,
                settings: request.settings,
                maxPixelSize: request.maxPixelSize,
                quality: request.intent == .interactive ? .interactive : .settled
            )
            guard !Task.isCancelled, request.assetID == currentAssetID else { return }

            switch request.intent {
            case .interactive:
                // Serialized completions are monotonic. Showing a just-finished
                // frame while a newer one is pending provides fluid, bounded lag.
                guard request.generation > displayedGeneration else { return }
                rendered = result.cgImage
                displayedGeneration = request.generation
                errorMessage = nil
            case .settled:
                guard request.generation == generation else { return }
                rendered = result.cgImage
                settledImage = result.cgImage
                displayedGeneration = request.generation
                errorMessage = nil
                settledVersion &+= 1
                settledCache.removeAll {
                    $0.assetID == request.assetID && $0.settings == request.settings
                }
                settledCache.append(CachedRender(
                    assetID: request.assetID,
                    settings: request.settings,
                    image: result.cgImage
                ))
                if settledCache.count > 2 { settledCache.removeFirst() }
            }
        } catch is CancellationError {
            return
        } catch {
            guard request.generation == generation, request.assetID == currentAssetID else { return }
            if rendered == nil { errorMessage = error.localizedDescription }
        }
    }
}

struct DevelopPreview: View {
    let asset: ImageAsset
    let settings: DevelopSettings
    var onRender: (CGImage) -> Void = { _ in }

    @Environment(AppServices.self) private var services
    @State private var renderer = DevelopPreviewRenderer()

    private let interactivePixels = 1280
    private let settledPixels = 2400

    var body: some View {
        ZStack {
            if let rendered = renderer.rendered {
                Image(decorative: rendered, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
            } else if let error = renderer.errorMessage {
                missingState(error)
            } else {
                ProgressView().tint(Theme.textSecondary)
            }

            if renderer.isRendering && renderer.rendered != nil {
                ProgressView()
                    .tint(.white)
                    .padding(8)
                    .background(.black.opacity(0.4), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding()
            }
        }
        .task(id: PreviewTaskID(assetID: asset.id, settings: settings)) {
            renderer.submit(
                assetID: asset.id,
                source: AssetFileAccess.Reference(asset: asset),
                settings: settings,
                pipeline: services.pipeline,
                interactivePixels: interactivePixels,
                settledPixels: settledPixels
            )
        }
        .onChange(of: renderer.settledVersion) { _, _ in
            if let image = renderer.settledImage { onRender(image) }
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
