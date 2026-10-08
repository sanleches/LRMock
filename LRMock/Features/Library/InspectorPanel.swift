//
//  InspectorPanel.swift
//  RawLight
//
//  Right-side develop menu. Edits bind directly to the asset's `DevelopSettings`;
//  SwiftData autosaves the catalog, and `RootView` writes the portable sidecar
//  when the loupe closes. The live preview re-renders as values change.
//

import SwiftUI

struct InspectorPanel: View {
    @Bindable var asset: ImageAsset

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    metadataSummary

                    section("Light") {
                        slider("Exposure", $asset.develop.exposure)
                        slider("Contrast", $asset.develop.contrast)
                        slider("Highlights", $asset.develop.highlights)
                        slider("Shadows", $asset.develop.shadows)
                        slider("Whites", $asset.develop.whites)
                        slider("Blacks", $asset.develop.blacks)
                    }

                    section("Color") {
                        slider("Temp", $asset.develop.temperature, tint: .orange)
                        slider("Tint", $asset.develop.tint, tint: .green)
                        slider("Vibrance", $asset.develop.vibrance)
                        slider("Saturation", $asset.develop.saturation)
                    }

                    section("Detail") {
                        slider("Sharpening", $asset.develop.sharpness, range: 0...1)
                        slider("Noise Reduction", $asset.develop.noiseReduction, range: 0...1)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 300)
        .background(Theme.panel)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Edit").font(.headline).foregroundStyle(Theme.textPrimary)
            Spacer()
            if asset.hasEdits {
                Button("Reset") {
                    withAnimation { asset.develop.reset() }
                }
                .font(.subheadline)
                .tint(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Metadata

    private var metadataSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text([asset.cameraMake, asset.cameraModel].compactMap { $0 }.joined(separator: " "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
            Text(exifLine)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var exifLine: String {
        var parts: [String] = []
        if let f = asset.focalLength { parts.append("\(Int(f))mm") }
        if let a = asset.aperture { parts.append("f/\(String(format: "%.1f", a))") }
        if let s = asset.shutterSpeed { parts.append(s) }
        if let iso = asset.isoValue { parts.append("ISO \(iso)") }
        return parts.isEmpty ? "No EXIF" : parts.joined(separator: "  ·  ")
    }

    // MARK: Builders

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func slider(_ title: String,
                        _ value: Binding<Double>,
                        range: ClosedRange<Double> = -1...1,
                        tint: Color = Theme.accent) -> some View {
        AdjustmentSlider(title: title, value: value, range: range, tint: tint)
    }
}

/// A labelled slider with a value readout and double-tap-to-reset.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var tint: Color = Theme.accent

    private var resetValue: Double { range.lowerBound < 0 ? 0 : range.lowerBound }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: "%+.0f", value * 100))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(abs(value) > 0.001 ? Theme.textPrimary : Theme.textTertiary)
            }
            Slider(value: $value, in: range)
                .tint(tint)
                .onTapGesture(count: 2) { value = resetValue }
        }
    }
}
