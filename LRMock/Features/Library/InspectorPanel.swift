//
//  InspectorPanel.swift
//  RawLight
//
//  Dense, tabbed develop inspector: a live histogram on top, then Light / Color
//  / Curve / Effects / Detail / Info tabs of compact `ScrubSlider`s. Edits bind
//  straight to the asset's `DevelopSettings`; the preview re-renders live and
//  the sidecar autosaves.
//

import SwiftUI

struct InspectorPanel: View {
    @Bindable var asset: ImageAsset

    /// Latest rendered preview (for the histogram) + a version that bumps on
    /// each render so the histogram recomputes.
    var renderedImage: CGImage?
    var renderVersion: Int

    enum Tab: String, CaseIterable, Identifiable {
        case light, color, mix, grade, curve, effects, detail, info
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .light:   return "sun.max"
            case .color:   return "drop"
            case .mix:     return "paintpalette"
            case .grade:   return "circle.hexagongrid.fill"
            case .curve:   return "point.topleft.down.to.point.bottomright.curvepath"
            case .effects: return "wand.and.stars"
            case .detail:  return "circle.grid.cross"
            case .info:    return "info.circle"
            }
        }
    }

    @State private var tab: Tab = .light
    @State private var mixBand: Int = 0

    private static let bandNames = ["Red", "Orange", "Yellow", "Green",
                                    "Aqua", "Blue", "Purple", "Magenta"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)

            HistogramView(image: renderedImage, version: renderVersion)
                .frame(height: 64)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            tabBar
            Divider().overlay(Theme.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 310)
        .background(Theme.panel)
    }

    // MARK: Header

    @State private var confirmResetAll = false

    private var header: some View {
        HStack {
            Text("Develop").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if asset.hasEdits {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .help("This photo has edits")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { tab = t }
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(tab == t ? Theme.accent : Theme.textSecondary)
                        .background(alignment: .bottom) {
                            Rectangle()
                                .fill(tab == t ? Theme.accent : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: Tab content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .light:
            group("Tone") {
                slider("Exposure", $asset.develop.exposure)
                slider("Contrast", $asset.develop.contrast)
                slider("Highlights", $asset.develop.highlights)
                slider("Shadows", $asset.develop.shadows)
                slider("Whites", $asset.develop.whites)
                slider("Blacks", $asset.develop.blacks)
            }
        case .color:
            group("White Balance") {
                slider("Temp", $asset.develop.temperature, accent: .orange)
                slider("Tint", $asset.develop.tint, accent: .green)
            }
            group("Vibrancy") {
                slider("Vibrance", $asset.develop.vibrance)
                slider("Saturation", $asset.develop.saturation)
            }
            group("Black & White") {
                Toggle(isOn: $asset.develop.blackWhite) {
                    Text("Convert to B&W").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .tint(Theme.accent)
                if asset.develop.blackWhite {
                    slider("Red", $asset.develop.bwRed, accent: .red)
                    slider("Green", $asset.develop.bwGreen, accent: .green)
                    slider("Blue", $asset.develop.bwBlue, accent: .blue)
                }
            }
        case .mix:
            group("Color Mixer") {
                bandSelector
                Text(Self.bandNames[mixBand])
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                slider("Hue", $asset.develop.colorMix.hue[mixBand], accent: bandColor(mixBand))
                slider("Saturation", $asset.develop.colorMix.saturation[mixBand], accent: bandColor(mixBand))
                slider("Luminance", $asset.develop.colorMix.luminance[mixBand], accent: bandColor(mixBand))
            }
        case .grade:
            gradeGroup("Shadows", hue: $asset.develop.grade.shadowHue, sat: $asset.develop.grade.shadowSat)
            gradeGroup("Midtones", hue: $asset.develop.grade.midHue, sat: $asset.develop.grade.midSat)
            gradeGroup("Highlights", hue: $asset.develop.grade.highHue, sat: $asset.develop.grade.highSat)
        case .curve:
            group("Tone Curve") {
                channelSelector
                ToneCurveEditor(points: curveBinding)
                    .padding(.vertical, 4)
                Button("Reset Channel") {
                    withAnimation { curveBinding.wrappedValue = DevelopSettings.linearCurve }
                }
                .font(.system(size: 12))
                .tint(Theme.accent)
                .disabled(asset.develop.isCurveLinear(curveBinding.wrappedValue))
            }
        case .effects:
            group("Presence") {
                slider("Texture", $asset.develop.texture)
                slider("Clarity", $asset.develop.clarity)
                slider("Dehaze", $asset.develop.dehaze)
            }
            group("Effects") {
                slider("Vignette", $asset.develop.vignette)
                slider("Grain", $asset.develop.grain, range: 0...1, defaultValue: 0)
            }
        case .detail:
            group("Sharpening") {
                slider("Amount", $asset.develop.sharpness, range: 0...1, defaultValue: 0)
                slider("Radius", $asset.develop.sharpenRadius, range: 0...1, defaultValue: 0)
            }
            group("Noise Reduction") {
                slider("Luminance", $asset.develop.noiseReduction, range: 0...1, defaultValue: 0)
                slider("Color", $asset.develop.colorNoiseReduction, range: 0...1, defaultValue: 0)
            }
        case .info:
            metadata
        }
    }

    // MARK: Curve channel

    enum CurveChannel: String, CaseIterable { case lum = "RGB", red = "R", green = "G", blue = "B" }
    @State private var curveChannel: CurveChannel = .lum

    private var curveBinding: Binding<[CurvePoint]> {
        switch curveChannel {
        case .lum:   return $asset.develop.toneCurve
        case .red:   return $asset.develop.toneCurveRed
        case .green: return $asset.develop.toneCurveGreen
        case .blue:  return $asset.develop.toneCurveBlue
        }
    }

    private var channelSelector: some View {
        HStack(spacing: 6) {
            ForEach(CurveChannel.allCases, id: \.self) { ch in
                Button {
                    curveChannel = ch
                } label: {
                    Text(ch.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(curveChannel == ch ? channelColor(ch).opacity(0.25) : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(curveChannel == ch ? channelColor(ch) : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func channelColor(_ ch: CurveChannel) -> Color {
        switch ch {
        case .lum: return Theme.textPrimary
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }

    // MARK: Grade

    @ViewBuilder
    private func gradeGroup(_ title: String, hue: Binding<Double>, sat: Binding<Double>) -> some View {
        group(title) {
            ScrubSlider(title: "Hue", value: hue, range: 0...1, defaultValue: 0,
                        displayScale: 360, accent: Color(hue: hue.wrappedValue, saturation: 0.8, brightness: 0.95))
            ScrubSlider(title: "Saturation", value: sat, range: 0...1, defaultValue: 0,
                        accent: Color(hue: hue.wrappedValue, saturation: 0.8, brightness: 0.95))
        }
    }

    // MARK: Builders

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            content()
        }
    }

    private func slider(_ title: String,
                        _ value: Binding<Double>,
                        range: ClosedRange<Double> = -1...1,
                        defaultValue: Double = 0,
                        accent: Color = Theme.accent) -> some View {
        ScrubSlider(title: title, value: value, range: range,
                    defaultValue: defaultValue, accent: accent)
    }

    // MARK: Color Mixer band selector

    private var bandSelector: some View {
        HStack(spacing: 6) {
            ForEach(0..<ColorMix.bandCount, id: \.self) { b in
                let edited = asset.develop.colorMix.hue[b] != 0
                    || asset.develop.colorMix.saturation[b] != 0
                    || asset.develop.colorMix.luminance[b] != 0
                Circle()
                    .fill(bandColor(b))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle().strokeBorder(.white, lineWidth: mixBand == b ? 2 : 0)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if edited {
                            Circle().fill(.white).frame(width: 5, height: 5)
                        }
                    }
                    .onTapGesture { mixBand = b }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bandColor(_ band: Int) -> Color {
        Color(hue: ColorCubeEngine.bandCenters[band] / 360, saturation: 0.75, brightness: 0.95)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            infoRow("Camera", [asset.cameraMake, asset.cameraModel].compactMap { $0 }.joined(separator: " "))
            infoRow("Lens", asset.lensModel ?? "—")
            infoRow("Exposure", exifLine)
            infoRow("Dimensions", asset.pixelWidth > 0 ? "\(asset.pixelWidth) × \(asset.pixelHeight)" : "—")
            infoRow("File", asset.originalFilename)

            Divider().overlay(Theme.separator).padding(.vertical, 4)

            Button(role: .destructive) {
                confirmResetAll = true
            } label: {
                Label("Reset All Adjustments", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!asset.hasEdits)
            .confirmationDialog("Reset all adjustments on this photo?",
                                isPresented: $confirmResetAll, titleVisibility: .visible) {
                Button("Reset Everything", role: .destructive) {
                    withAnimation { asset.develop.reset() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every develop setting. Your original file is not affected.")
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            Spacer()
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var exifLine: String {
        var parts: [String] = []
        if let f = asset.focalLength { parts.append("\(Int(f))mm") }
        if let a = asset.aperture { parts.append("f/\(String(format: "%.1f", a))") }
        if let s = asset.shutterSpeed { parts.append(s) }
        if let iso = asset.isoValue { parts.append("ISO \(iso)") }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }
}
