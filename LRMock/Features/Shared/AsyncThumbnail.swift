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
        // Resolve the file (scoped if external), generate/fetch the thumbnail,
        // then release access. Thumbnail work happens inside the service actor.
        guard let handle = try? AssetFileAccess.open(asset) else {
            failed = true
            return
        }
        let id = asset.id
        let url = handle.url
        let result = await ThumbnailService.shared.thumbnail(for: id, fileURL: url)
        handle.release()

        if let result {
            image = result
        } else {
            failed = true
        }
    }
}
