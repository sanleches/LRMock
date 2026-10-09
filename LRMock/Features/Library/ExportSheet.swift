//
//  ExportSheet.swift
//  RawLight
//
//  Renders the asset at the chosen settings through the active `RawPipeline`,
//  then lets the user save it to a location (native Save panel on macOS, the
//  document save UI on iPadOS) via `.fileExporter`, or hand it to the share
//  sheet. All encoding lives in the pipeline; this view is options + I/O.
//

import SwiftUI
import UniformTypeIdentifiers

/// Wraps already-encoded image bytes so `.fileExporter` can write them to a
/// user-chosen destination on any platform.
struct ExportedImageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.jpeg, .heic, .tiff, .png] }

    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ExportSheet: View {
    let asset: ImageAsset

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    // Options.
    @State private var format: ExportOptions.Format = .jpeg
    @State private var colorSpace: ExportOptions.ColorSpace = .sRGB
    @State private var size: SizeChoice = .full
    @State private var quality: Double = 0.9

    // Result.
    @State private var document: ExportedImageDocument?
    @State private var exportedURL: URL?
    @State private var showExporter = false
    @State private var isExporting = false
    @State private var statusText: String?
    @State private var isError = false

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

    private var outputType: UTType {
        switch format {
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .png:  return .png
        }
    }

    private var suggestedName: String {
        (asset.originalFilename as NSString).deletingPathExtension + "_edited"
    }

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

                if let statusText {
                    Section { Text(statusText).foregroundStyle(isError ? .red : .secondary) }
                }

                Section {
                    Button {
                        Task { await exportToFolder() }
                    } label: {
                        HStack {
                            Label("Export to Folder…", systemImage: "square.and.arrow.down")
                            Spacer()
                            if isExporting { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isExporting)

                    if let exportedURL {
                        ShareLink(item: exportedURL) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                    }
                } footer: {
                    Text("Export saves a rendered copy. Your original is never modified.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 540, idealHeight: 560)
        .fileExporter(
            isPresented: $showExporter,
            document: document,
            contentType: outputType,
            defaultFilename: suggestedName
        ) { result in
            switch result {
            case .success:
                statusText = "Exported."; isError = false
            case .failure:
                statusText = "Could not save to that location."; isError = true
            }
        }
        .onChange(of: format) { _, _ in invalidate() }
        .onChange(of: colorSpace) { _, _ in invalidate() }
        .onChange(of: size) { _, _ in invalidate() }
        .onChange(of: quality) { _, _ in invalidate() }
    }

    // MARK: Actions

    private func invalidate() {
        document = nil
        exportedURL = nil
        statusText = nil
    }

    /// Renders the output, then saves it to a user-chosen folder.
    /// macOS uses a native `NSSavePanel`; iPadOS uses `.fileExporter`.
    private func exportToFolder() async {
        guard await render() else { return }
        #if os(macOS)
        switch await ExportDestination.runSavePanel(
            data: document?.data ?? Data(),
            suggestedName: suggestedName, type: outputType) {
        case .saved: statusText = "Exported to the chosen folder."; isError = false
        case .cancelled: statusText = nil
        case .failed: statusText = "Could not save to that location."; isError = true
        }
        #else
        showExporter = true
        #endif
    }

    @discardableResult
    private func render() async -> Bool {
        statusText = nil
        isError = false
        isExporting = true
        defer { isExporting = false }

        guard let handle = try? AssetFileAccess.open(asset) else {
            statusText = "Original file is unavailable."
            isError = true
            return false
        }
        defer { handle.release() }

        var options = ExportOptions()
        options.format = format
        options.colorSpace = colorSpace
        options.maxPixelSize = size.pixels
        options.quality = quality

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suggestedName).\(format.rawValue)")
        try? FileManager.default.removeItem(at: destination)

        do {
            let url = try await services.pipeline.export(
                fileURL: handle.url, settings: asset.develop,
                options: options, to: destination)
            exportedURL = url
            document = ExportedImageDocument(data: try Data(contentsOf: url))
            return true
        } catch {
            statusText = "Export failed. Try a different format."
            isError = true
            return false
        }
    }
}
