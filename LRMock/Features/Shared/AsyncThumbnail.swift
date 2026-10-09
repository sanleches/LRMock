//
//  AsyncThumbnail.swift
//  RawLight
//
//  Loads an asset's grid thumbnail off the main thread and fades it in, showing
//  a neutral placeholder (or a "missing file" state) in the meantime.
//
//  All file access (bookmark resolution + scoped access) is funnelled through
//  `AssetFileAccess`, and generation/caching through `ThumbnailService`, so this
//  view stays purely about presentation.
//

import SwiftUI

struct AsyncThumbnail: View {
    let asset: ImageAsset
    var maxPixelSize = 512

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        // Take exactly the offered size and clip the fill overflow, so the image
        // never drives the parent's layout.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .task(id: asset.id) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Theme.surface
            Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                .font(.title3)
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func load() async {
        let id = asset.id
        let source = AssetFileAccess.Reference(asset: asset)
        let sourceVersion = asset.contentDigest ?? "\(asset.fileSizeBytes):\(asset.importedAt.timeIntervalSince1970)"
        let result = await ThumbnailService.shared.thumbnail(
            for: id,
            source: source,
            sourceVersion: sourceVersion,
            maxPixelSize: maxPixelSize
        )
        guard !Task.isCancelled else { return }

        if let result {
            image = result
        } else {
            failed = true
        }
    }
}
