//
//  ExportSheet.swift
//  RawLight
//
//  Renders the asset at the chosen settings through the active `RawPipeline`
//  and hands the resulting file to the system share sheet (save to Files, AirDrop,
//  etc.). All encoding lives in the pipeline; this view is just options + I/O
//  orchestration.
//

import SwiftUI

struct ExportSheet: View {
    let asset: ImageAsset

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    // User-facing option state.
    @State private var format: ExportOptions.Format = .jpeg
    @State private var colorSpace: ExportOptions.ColorSpace = .sRGB
    @State private var size: SizeChoice = .full
    @State private var quality: Double = 0.9

    // Result state.
    @State private var exportedURL: URL?
    @State private var isExporting = false
    @State private var errorText: String?

    /// Longest-edge presets offered to the user.
    enum SizeChoice: String, CaseIterable, Identifiable {
        case full = "Full size"
        case px4096 = "4096 px"
        case px2048 = "2048 px"
        case px1024 = "1024 px"
        var id: String { rawValue }
        var pixels: Int? {
            switch self {
            case .full: return nil
            case .px4096: return 4096
            case .px2048: return 2048
            case .px1024: return 1024
            }
        }
    }

    private var isLossy: Bool { format == .jpeg || format == .heic }

    var body: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("File type", selection: $format) {
                        Text("JPEG").tag(ExportOptions.Format.jpeg)
                        Text("HEIC").tag(ExportOptions.Format.heic)
                        Text("TIFF").tag(ExportOptions.Format.tiff)
                        Text("PNG").tag(ExportOptions.Format.png)
                    }
                    Picker("Color space", selection: $colorSpace) {
                        Text("sRGB").tag(ExportOptions.ColorSpace.sRGB)
                        Text("Display P3").tag(ExportOptions.ColorSpace.displayP3)
                        Text("Adobe RGB").tag(ExportOptions.ColorSpace.adobeRGB)
                    }
                    Picker("Size", selection: $size) {
                        ForEach(SizeChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if isLossy {
                        VStack(alignment: .leading) {
                            Text("Quality \(Int(quality * 100))%")
                            Slider(value: $quality, in: 0.1...1)
                        }
                    }
                }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }

                Section {
                    if let exportedURL {
                        ShareLink(item: exportedURL) {
                            Label("Share / Save…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        Task { await runExport() }
                    } label: {
                        HStack {
                            Text(exportedURL == nil ? "Create Export" : "Re-export")
                            if isExporting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isExporting)
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Re-rendering invalidates any previous output file.
        .onChange(of: format) { _, _ in exportedURL = nil }
        .onChange(of: colorSpace) { _, _ in exportedURL = nil }
        .onChange(of: size) { _, _ in exportedURL = nil }
        .onChange(of: quality) { _, _ in exportedURL = nil }
    }

    // MARK: Export

    private func runExport() async {
        errorText = nil
        isExporting = true
        defer { isExporting = false }

        guard let handle = try? AssetFileAccess.open(asset) else {
            errorText = "Original file is unavailable."
            return
        }
        defer { handle.release() }

        var options = ExportOptions()
        options.format = format
        options.colorSpace = colorSpace
        options.maxPixelSize = size.pixels
        options.quality = quality

        let base = (asset.originalFilename as NSString).deletingPathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(base)_edited.\(format.rawValue)")
        try? FileManager.default.removeItem(at: destination)

        do {
            let url = try await services.pipeline.export(
                fileURL: handle.url,
                settings: asset.develop,
                options: options,
                to: destination
            )
            exportedURL = url
        } catch {
            errorText = "Export failed. Try a different format."
        }
    }
}
