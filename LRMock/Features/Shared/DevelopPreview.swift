//
//  DevelopPreview.swift
//  RawLight
//
//  Renders a single asset with its current `DevelopSettings` applied, using the
//  active `RawPipeline`. Lives in the loupe view.
//
//  Re-rendering is debounced: `.task(id:)` cancels the in-flight render whenever
//  the settings change, and we sleep briefly before doing the (relatively) heavy
//  decode so dragging a slider doesn't queue dozens of full renders.
//

import SwiftUI

struct DevelopPreview: View {
    let asset: ImageAsset
    /// Current recipe. Passed by value so `.task(id:)` can diff it (Equatable).
    let settings: DevelopSettings

    @Environment(AppServices.self) private var services

    /// Re-render trigger: changes when either the recipe or the engine changes.
    private struct RenderKey: Equatable {
        var settings: DevelopSettings
        var engine: PipelineKind
    }

    @State private var rendered: CGImage?
    @State private var isRendering = false
    @State private var failed = false

    /// Longest-edge pixel budget for on-screen preview.
    private let maxPreviewPixels = 2048

    var body: some View {
        ZStack {
            if let rendered {
                Image(decorative: rendered, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                missingState
            } else {
                ProgressView().tint(Theme.textSecondary)
            }

            if isRendering && rendered != nil {
                // Subtle activity hint while a new render replaces the old one.
                ProgressView()
                    .tint(.white)
                    .padding(8)
                    .background(.black.opacity(0.4), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding()
            }
        }
        .task(id: RenderKey(settings: settings, engine: services.engine)) { await render() }
    }

    private var missingState: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Original file unavailable")
                .font(.callout)
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private func render() async {
        // Debounce rapid settings changes.
        try? await Task.sleep(for: .milliseconds(120))
        if Task.isCancelled { return }

        guard let handle = try? AssetFileAccess.open(asset) else {
            failed = true
            return
        }
        let url = handle.url
        defer { handle.release() }

        isRendering = true
        defer { isRendering = false }

        do {
            let result = try await services.pipeline.renderPreview(
                fileURL: url, settings: settings, maxPixelSize: maxPreviewPixels
            )
            if !Task.isCancelled {
                rendered = result.cgImage
                failed = false
            }
        } catch {
            if rendered == nil { failed = true }
        }
    }
}
