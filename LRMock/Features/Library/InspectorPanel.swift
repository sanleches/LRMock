//
//  InspectorPanel.swift
//  RawLight
//
//  Dense, tabbed develop inspector with a live histogram and compact
//  `ScrubSlider` groups. Edits bind straight to the asset's `DevelopSettings`;
//  the preview re-renders live and the sidecar autosaves.
//

import SwiftUI

struct InspectorPanel: View {
    @Bindable var asset: ImageAsset
    @Bindable var session: DevelopToolSession
    let history: DevelopHistoryCoordinator

    /// Latest rendered preview (for the histogram) + a version that bumps on
    /// each render so the histogram recomputes.
    var renderedImage: CGImage?
    var renderVersion: Int
    var onActivateTool: (DevelopToolSession.Tool) -> Void = { _ in }

    enum Tab: String, CaseIterable, Identifiable {
        case light, color, mix, masking, retouch, grade, curve, effects, detail
        case optics, geometry, calibration, info
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light: return "Light"
            case .color: return "Color"
            case .mix: return "Color Mixer"
            case .masking: return "Masking"
            case .retouch: return "Retouch"
            case .grade: return "Color Grading"
            case .curve: return "Tone Curve"
            case .effects: return "Effects"
            case .detail: return "Detail"
            case .optics: return "Optics"
            case .geometry: return "Geometry"
            case .calibration: return "Calibration"
            case .info: return "Info"
            }
        }
        var icon: String {
            switch self {
            case .light:   return "sun.max"
            case .color:   return "drop"
            case .mix:     return "paintpalette"
            case .masking: return "circle.lefthalf.filled"
            case .retouch: return "bandage"
            case .grade:   return "circle.hexagongrid.fill"
            case .curve:   return "point.topleft.down.to.point.bottomright.curvepath"
            case .effects: return "wand.and.stars"
            case .detail:  return "circle.grid.cross"
            case .optics:  return "camera.aperture"
            case .geometry: return "perspective"
            case .calibration: return "dial.medium"
            case .info:    return "info.circle"
            }
        }
    }

    @State private var tab: Tab = .light
    @State private var mixBand: Int = 0
    @State private var blackWhiteBand: BlackWhiteBand = .red
    @State private var mixSection: MixSection = .mixer
    @State private var retouchSection: RetouchSection = .spot
    @State private var developTransaction: DevelopHistoryTransaction?
    @State private var developTransactionOwner: UUID?

    private enum MixSection: String, CaseIterable, Identifiable {
        case mixer = "Mixer"
        case pointColor = "Point Color"
        var id: Self { self }
    }

    private enum RetouchSection: String, CaseIterable, Identifiable {
        case spot = "Spot"
        case redEye = "Red Eye"
        var id: Self { self }
    }

    private static let bandNames = ["Red", "Orange", "Yellow", "Green",
                                    "Aqua", "Blue", "Purple", "Magenta"]

    private enum BlackWhiteBand: String, CaseIterable, Identifiable {
        case red = "Red"
        case orange = "Orange"
        case yellow = "Yellow"
        case green = "Green"
        case aqua = "Aqua"
        case blue = "Blue"
        case purple = "Purple"
        case magenta = "Magenta"

        var id: Self { self }
        var color: Color {
            switch self {
            case .red: return .red
            case .orange: return .orange
            case .yellow: return .yellow
            case .green: return .green
            case .aqua: return .cyan
            case .blue: return .blue
            case .purple: return .purple
            case .magenta: return .pink
            }
        }
    }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel.ignoresSafeArea())
        .onChange(of: asset.id) { _, _ in
            developTransaction = nil
            developTransactionOwner = nil
        }
        .onDisappear { endActiveDevelopChange() }
    }

    // MARK: Header

    @State private var confirmResetAll = false

    private var header: some View {
        HStack(spacing: 4) {
            Text("Develop").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if asset.hasEdits {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .help("This photo has edits")
            }
            Button(action: undo) {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: actionSize, height: actionSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(history.canUndo ? Theme.textSecondary : Theme.textTertiary)
            .disabled(!history.canUndo)
            .help("Undo Develop Change")
            .accessibilityLabel("Undo")

            Button(action: redo) {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: actionSize, height: actionSize)
            }
            .buttonStyle(.plain)
            .foregroundStyle(history.canRedo ? Theme.textSecondary : Theme.textTertiary)
            .disabled(!history.canRedo)
            .help("Redo Develop Change")
            .accessibilityLabel("Redo")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Tab.allCases) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { tab = t }
                    } label: {
                        Image(systemName: t.icon)
                            .font(.system(size: 15))
                            .frame(width: tabItemWidth, height: actionSize)
                            .foregroundStyle(tab == t ? Theme.accent : Theme.textSecondary)
                            .background(alignment: .bottom) {
                                Rectangle()
                                    .fill(tab == t ? Theme.accent : .clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(t.title)
                    .accessibilityLabel(t.title)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }
            .padding(.horizontal, 6)
        }
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
            group("Profile") {
                slider("Amount", $asset.develop.profileAmount,
                       range: 0...2, defaultValue: 1, displayScale: 100, accent: .cyan)
                    .help("Strength of the built-in RawLight color profile")
                    .accessibilityHint("Adjusts the built-in RawLight color profile")
            }
            group("White Balance") {
                slider("Temp", $asset.develop.temperature, accent: .orange)
                slider("Tint", $asset.develop.tint, accent: .green)
            }
            group("Vibrancy") {
                slider("Vibrance", $asset.develop.vibrance)
                slider("Saturation", $asset.develop.saturation)
            }
            group("Black & White") {
                Toggle(isOn: blackWhiteBinding) {
                    Text("Convert to B&W").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .tint(Theme.accent)
                .frame(minHeight: actionSize)
                if asset.develop.blackWhite {
                    blackWhiteBandSelector
                    HStack(spacing: 6) {
                        Circle()
                            .fill(blackWhiteBand.color)
                            .frame(width: 7, height: 7)
                        Text(blackWhiteBand.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    slider("Mix", blackWhiteBinding(for: blackWhiteBand),
                           accent: blackWhiteBand.color)
                }
            }
        case .mix:
            mixerContent
        case .masking:
            maskingContent
        case .retouch:
            retouchContent
        case .grade:
            gradeGroup("Shadows", hue: $asset.develop.grade.shadowHue,
                       saturation: $asset.develop.grade.shadowSat,
                       luminance: $asset.develop.grade.shadowLum)
            gradeGroup("Midtones", hue: $asset.develop.grade.midHue,
                       saturation: $asset.develop.grade.midSat,
                       luminance: $asset.develop.grade.midLum)
            gradeGroup("Highlights", hue: $asset.develop.grade.highHue,
                       saturation: $asset.develop.grade.highSat,
                       luminance: $asset.develop.grade.highLum)
            gradeGroup("Global", hue: $asset.develop.grade.globalHue,
                       saturation: $asset.develop.grade.globalSat,
                       luminance: $asset.develop.grade.globalLum)
            group("Ranges") {
                slider("Blending", $asset.develop.grade.blending,
                       range: 0...1, defaultValue: 0.5)
                slider("Balance", $asset.develop.grade.balance)
            }
        case .curve:
            group("Parametric Curve") {
                slider("Highlights", $asset.develop.curveHighlights, accent: .white)
                slider("Lights", $asset.develop.curveLights, accent: .gray)
                slider("Darks", $asset.develop.curveDarks, accent: .gray)
                slider("Shadows", $asset.develop.curveShadows, accent: .white)
            }
            group("Parametric Ranges") {
                slider("Shadow Split", $asset.develop.curveSplitShadows,
                       range: 0...1, defaultValue: 0.25)
                slider("Midtone Split", $asset.develop.curveSplitMid,
                       range: 0...1, defaultValue: 0.5)
                slider("Highlight Split", $asset.develop.curveSplitHighlights,
                       range: 0...1, defaultValue: 0.75)
                slider("Refine Saturation", $asset.develop.curveRefineSaturation,
                       range: 0...1, defaultValue: 1, accent: .pink)
            }
            group("Tone Curve") {
                channelSelector
                ToneCurveEditor(
                    points: curveBinding,
                    onEditingChanged: handleSliderEditing
                )
                    .padding(.vertical, 4)
                Button("Reset Channel") {
                    withAnimation {
                        performDevelopChange {
                            curveBinding.wrappedValue = DevelopSettings.linearCurve
                        }
                    }
                }
                .font(.system(size: 12))
                .tint(Theme.accent)
                .frame(minHeight: actionSize)
                .disabled(asset.develop.isCurveLinear(curveBinding.wrappedValue))
            }
        case .effects:
            group("Presence") {
                slider("Texture", $asset.develop.texture)
                slider("Clarity", $asset.develop.clarity)
                slider("Dehaze", $asset.develop.dehaze)
            }
            group("Vignette") {
                slider("Amount", $asset.develop.vignette, accent: .indigo)
                slider("Midpoint", $asset.develop.vignetteMidpoint,
                       range: 0...1, defaultValue: 0.5, accent: .indigo)
                slider("Roundness", $asset.develop.vignetteRoundness, accent: .indigo)
                slider("Feather", $asset.develop.vignetteFeather,
                       range: 0...1, defaultValue: 0.5, accent: .indigo)
                slider("Highlights", $asset.develop.vignetteHighlights,
                       range: 0...1, defaultValue: 0, accent: .indigo)
            }
            group("Grain") {
                slider("Amount", $asset.develop.grain,
                       range: 0...1, defaultValue: 0, accent: .brown)
                slider("Size", $asset.develop.grainSize,
                       range: 0...1, defaultValue: 0.25, accent: .brown)
                slider("Roughness", $asset.develop.grainRoughness,
                       range: 0...1, defaultValue: 0.5, accent: .brown)
            }
        case .detail:
            group("Sharpening") {
                slider("Amount", $asset.develop.sharpness, range: 0...1, defaultValue: 0)
                slider("Radius", $asset.develop.sharpenRadius, range: 0...1, defaultValue: 0)
                slider("Detail", $asset.develop.sharpenDetail, range: 0...1, defaultValue: 0.25)
                slider("Masking", $asset.develop.sharpenMasking, range: 0...1, defaultValue: 0)
            }
            group("Luminance Noise") {
                slider("Luminance", $asset.develop.noiseReduction, range: 0...1, defaultValue: 0)
                slider("Detail", $asset.develop.noiseReductionDetail, range: 0...1, defaultValue: 0.5)
                slider("Contrast", $asset.develop.noiseReductionContrast, range: 0...1, defaultValue: 0)
            }
            group("Color Noise") {
                slider("Color", $asset.develop.colorNoiseReduction,
                       range: 0...1, defaultValue: 0, accent: .purple)
                slider("Detail", $asset.develop.colorNoiseReductionDetail,
                       range: 0...1, defaultValue: 0.5, accent: .purple)
                slider("Smoothness", $asset.develop.colorNoiseReductionSmoothness,
                       range: 0...1, defaultValue: 0.5, accent: .purple)
            }
        case .optics:
            group("Manual Correction") {
                slider("Distortion", $asset.develop.opticsDistortion, accent: .orange)
                slider("Vignetting", $asset.develop.opticsVignetting, accent: .indigo)
                slider("Vignette Midpoint", $asset.develop.opticsVignettingMidpoint,
                       range: 0...1, defaultValue: 0.5, accent: .indigo)
            }
            group("Correction Strength") {
                slider("Distortion Strength", $asset.develop.opticsProfileDistortion,
                       range: 0...2, defaultValue: 1, accent: .orange)
                    .help("Scales the manual distortion correction; no lens database is used")
                    .accessibilityHint("Scales manual distortion correction, not a lens profile")
                slider("Vignetting Strength", $asset.develop.opticsProfileVignetting,
                       range: 0...2, defaultValue: 1, accent: .indigo)
                    .help("Scales the manual vignetting correction; no lens database is used")
                    .accessibilityHint("Scales manual vignetting correction, not a lens profile")
                Text("Strength scales the manual correction above; no lens database is applied.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            group("Purple Defringe") {
                slider("Amount", $asset.develop.opticsDefringePurple,
                       range: 0...1, defaultValue: 0, accent: .purple)
                slider("Low Hue", $asset.develop.opticsDefringePurpleHueLo,
                       range: 0...1, defaultValue: 0.3, displayScale: 360, accent: .purple)
                slider("High Hue", $asset.develop.opticsDefringePurpleHueHi,
                       range: 0...1, defaultValue: 0.7, displayScale: 360, accent: .purple)
            }
            group("Green Defringe") {
                slider("Amount", $asset.develop.opticsDefringeGreen,
                       range: 0...1, defaultValue: 0, accent: .green)
                slider("Low Hue", $asset.develop.opticsDefringeGreenHueLo,
                       range: 0...1, defaultValue: 0.4, displayScale: 360, accent: .green)
                slider("High Hue", $asset.develop.opticsDefringeGreenHueHi,
                       range: 0...1, defaultValue: 0.6, displayScale: 360, accent: .green)
            }
            group("Chromatic Aberration") {
                slider("Red Shift", $asset.develop.opticsCARed, accent: .red)
                slider("Blue Shift", $asset.develop.opticsCABlue, accent: .blue)
            }
        case .geometry:
            group("Perspective") {
                slider("Vertical", $asset.develop.geometryVertical, accent: .orange)
                slider("Horizontal", $asset.develop.geometryHorizontal, accent: .orange)
            }
            group("Transform") {
                slider("Aspect", $asset.develop.geometryAspect, accent: .cyan)
                slider("Scale", $asset.develop.geometryScale,
                       range: 0.5...1.5, defaultValue: 1, accent: .cyan)
                slider("Offset X", $asset.develop.geometryOffsetX, accent: .cyan)
                slider("Offset Y", $asset.develop.geometryOffsetY, accent: .cyan)
            }
            Text("Crop, straighten, rotate, and flip remain in Crop & Rotate for direct manipulation.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .calibration:
            group("Shadows") {
                slider("Tint", $asset.develop.calibrationShadowsTint, accent: .green)
            }
            group("Red Primary") {
                slider("Hue", $asset.develop.calibrationRedHue, accent: .red)
                slider("Saturation", $asset.develop.calibrationRedSat, accent: .red)
            }
            group("Green Primary") {
                slider("Hue", $asset.develop.calibrationGreenHue, accent: .green)
                slider("Saturation", $asset.develop.calibrationGreenSat, accent: .green)
            }
            group("Blue Primary") {
                slider("Hue", $asset.develop.calibrationBlueHue, accent: .blue)
                slider("Saturation", $asset.develop.calibrationBlueSat, accent: .blue)
            }
        case .info:
            metadata
        }
    }

    // MARK: Selective edits

    @ViewBuilder
    private var mixerContent: some View {
        Picker("Color mixer section", selection: $mixSection) {
            ForEach(MixSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: actionSize)

        if mixSection == .mixer {
            group("Color Mixer") {
                bandSelector
                Text(Self.bandNames[mixBand])
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                slider("Hue", $asset.develop.colorMix.hue[mixBand], accent: bandColor(mixBand))
                slider("Saturation", $asset.develop.colorMix.saturation[mixBand], accent: bandColor(mixBand))
                slider("Luminance", $asset.develop.colorMix.luminance[mixBand], accent: bandColor(mixBand))
            }
        } else {
            pointColorContent
        }
    }

    @ViewBuilder
    private var pointColorContent: some View {
        group("Point Color") {
            Button {
                activateDirectTool(.pointColor)
            } label: {
                Label("Sample Color on Photo", systemImage: "eyedropper")
                    .frame(maxWidth: .infinity, minHeight: actionSize)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!canActivateDirectTool(.pointColor))
            .accessibilityAddTraits(session.tool == .pointColor ? .isSelected : [])

            if asset.develop.pointColors.isEmpty {
                emptyState("Tap Sample Color, then tap a color in the photo.")
            } else {
                ForEach(asset.develop.pointColors) { adjustment in
                    pointColorRow(adjustment)
                }
            }
        }

        if let id = session.selectedPointColorID,
           asset.develop.pointColors.contains(where: { $0.id == id }) {
            group("Selected Point Color") {
                slider("Hue Shift", pointColorBinding(id, \.hueShift))
                slider("Saturation", pointColorBinding(id, \.saturationShift))
                slider("Luminance", pointColorBinding(id, \.luminanceShift))
                slider("Variance", pointColorBinding(id, \.variance))
                slider("Range", pointColorBinding(id, \.range, fallback: 0.5),
                       range: 0...1, defaultValue: 0.5)
            }
        }
    }

    private func pointColorRow(_ adjustment: PointColorAdjustment) -> some View {
        HStack(spacing: 6) {
            Button {
                session.selectedPointColorID = adjustment.id
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(PointColorPresentation.swatch(adjustment))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                    Text("Sample")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if session.selectedPointColorID == adjustment.id {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: actionSize)
                .padding(.horizontal, 8)
                .background(
                    session.selectedPointColorID == adjustment.id
                        ? Theme.accent.opacity(0.12) : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Point color sample")
            .accessibilityAddTraits(
                session.selectedPointColorID == adjustment.id ? .isSelected : []
            )

            deleteButton("Delete point color") {
                deletePointColor(adjustment.id)
            }
        }
    }

    @ViewBuilder
    private var maskingContent: some View {
        group("Create Mask") {
            HStack(spacing: 6) {
                maskToolButton("Brush", icon: "paintbrush.pointed", tool: .brush)
                maskToolButton("Linear", icon: "rectangle.split.3x1", tool: .linearGradient)
                maskToolButton("Radial", icon: "circle.dashed", tool: .radialGradient)
            }
        }

        group("Masks") {
            if asset.develop.masks.isEmpty {
                emptyState("Choose a mask type, then draw on the photo.")
            } else {
                ForEach(asset.develop.masks) { mask in
                    maskRow(mask)
                }
            }
        }

        if selectedMask == nil, session.tool == .brush {
            group("Brush Defaults") {
                toolSlider("Size", $session.brushSize, range: 0.001...0.25,
                           defaultValue: 0.03, displayScale: 100)
                toolSlider("Feather", $session.brushFeather, range: 0...1,
                           defaultValue: 0.5)
                toolSlider("Flow", $session.brushFlow, range: 0...1, defaultValue: 1)
                toolSlider("Density", $session.brushDensity, range: 0...1, defaultValue: 1)
                Toggle("Erase", isOn: $session.brushErase)
                    .tint(Theme.accent)
                    .frame(minHeight: actionSize)
            }
        }

        if let mask = selectedMask {
            group("Selected Mask") {
                Toggle("Enabled", isOn: maskEnabledBinding(mask.id))
                    .tint(Theme.accent)
                    .frame(minHeight: actionSize)
                Toggle("Invert Mask", isOn: maskInvertedBinding(mask.id))
                    .tint(Theme.accent)
                    .frame(minHeight: actionSize)
            }

            if let component = mask.components.first {
                selectedShapeControls(maskID: mask.id, component: component)
            }

            group("Local Adjustments") {
                slider("Exposure", maskAdjustmentBinding(mask.id, \.exposure))
                slider("Temperature", maskAdjustmentBinding(mask.id, \.temperature), accent: .orange)
                slider("Tint", maskAdjustmentBinding(mask.id, \.tint), accent: .green)
                slider("Contrast", maskAdjustmentBinding(mask.id, \.contrast))
                slider("Highlights", maskAdjustmentBinding(mask.id, \.highlights))
                slider("Shadows", maskAdjustmentBinding(mask.id, \.shadows))
                slider("Whites", maskAdjustmentBinding(mask.id, \.whites))
                slider("Blacks", maskAdjustmentBinding(mask.id, \.blacks))
                slider("Texture", maskAdjustmentBinding(mask.id, \.texture))
                slider("Clarity", maskAdjustmentBinding(mask.id, \.clarity))
                slider("Dehaze", maskAdjustmentBinding(mask.id, \.dehaze))
                slider("Hue", maskAdjustmentBinding(mask.id, \.hue), accent: .pink)
                slider("Saturation", maskAdjustmentBinding(mask.id, \.saturation), accent: .pink)
                slider("Sharpness", maskAdjustmentBinding(mask.id, \.sharpness), accent: .cyan)
                slider("Noise Reduction", maskAdjustmentBinding(mask.id, \.noiseReduction), accent: .purple)
                slider("Amount", maskAdjustmentBinding(mask.id, \.amount, fallback: 1),
                       range: 0...2, defaultValue: 1)
            }
        }
    }

    private func maskToolButton(
        _ title: String,
        icon: String,
        tool: DevelopToolSession.Tool
    ) -> some View {
        Button {
            session.selectedMaskID = nil
            activateDirectTool(tool)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: actionSize)
        }
        .buttonStyle(.bordered)
        .tint(session.tool == tool ? Theme.accent : Theme.textSecondary)
        .disabled(!canActivateDirectTool(tool, selectedMaskID: nil))
        .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
    }

    private func maskRow(_ mask: LocalMask) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: maskEnabledBinding(mask.id))
                .labelsHidden()
                .tint(Theme.accent)
                .frame(minWidth: actionSize, minHeight: actionSize)
                .accessibilityLabel(mask.enabled ? "Disable mask" : "Enable mask")

            Button {
                selectMask(mask)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: maskShapeIcon(mask))
                        .foregroundStyle(mask.enabled ? Theme.accent : Theme.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mask.name.isEmpty ? "Mask" : mask.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(maskShapeName(mask))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: actionSize)
                .padding(.horizontal, 7)
                .background(
                    session.selectedMaskID == mask.id ? Theme.accent.opacity(0.12) : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(session.selectedMaskID == mask.id ? .isSelected : [])

            deleteButton("Delete \(mask.name.isEmpty ? "mask" : mask.name)") {
                deleteMask(mask.id)
            }
        }
    }

    @ViewBuilder
    private func selectedShapeControls(maskID: UUID, component: MaskComponent) -> some View {
        switch component.shape {
        case .brush:
            group("Brush") {
                toolSlider("Size", $session.brushSize, range: 0.001...0.25,
                           defaultValue: 0.03, displayScale: 100)
                toolSlider("Feather", $session.brushFeather, range: 0...1,
                           defaultValue: 0.5)
                toolSlider("Flow", $session.brushFlow, range: 0...1, defaultValue: 1)
                toolSlider("Density", $session.brushDensity, range: 0...1, defaultValue: 1)
                Toggle("Erase", isOn: $session.brushErase)
                    .tint(Theme.accent)
                    .frame(minHeight: actionSize)
            }
        case .linear:
            group("Linear Gradient") {
                slider("Start X", linearBinding(maskID, component.id, .startX),
                       range: 0...1, defaultValue: 0, displayScale: 100)
                slider("Start Y", linearBinding(maskID, component.id, .startY),
                       range: 0...1, defaultValue: 0.5, displayScale: 100)
                slider("End X", linearBinding(maskID, component.id, .endX),
                       range: 0...1, defaultValue: 1, displayScale: 100)
                slider("End Y", linearBinding(maskID, component.id, .endY),
                       range: 0...1, defaultValue: 0.5, displayScale: 100)
            }
        case .radial:
            group("Radial Gradient") {
                slider("Radius X", radialBinding(maskID, component.id, .radiusX),
                       range: 0.0001...1, defaultValue: 0.25)
                slider("Radius Y", radialBinding(maskID, component.id, .radiusY),
                       range: 0.0001...1, defaultValue: 0.25)
                slider("Angle", radialBinding(maskID, component.id, .angle),
                       range: -180...180, defaultValue: 0, displayScale: 1)
                slider("Feather", radialBinding(maskID, component.id, .feather),
                       range: 0...1, defaultValue: 0.5)
                Toggle("Invert Shape", isOn: radialInvertedBinding(maskID, component.id))
                    .tint(Theme.accent)
                    .frame(minHeight: actionSize)
            }
        }
    }

    @ViewBuilder
    private var retouchContent: some View {
        Picker("Retouch section", selection: $retouchSection) {
            ForEach(RetouchSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: actionSize)

        if retouchSection == .spot {
            spotContent
        } else {
            redEyeContent
        }
    }

    @ViewBuilder
    private var spotContent: some View {
        group("Spot Tool") {
            Picker("Mode", selection: spotModeRawBinding) {
                Text("Remove").tag(SpotMode.remove.rawValue)
                Text("Heal").tag(SpotMode.heal.rawValue)
                Text("Clone").tag(SpotMode.clone.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: actionSize)

            Button {
                session.selectedSpotID = nil
                activateDirectTool(.spot)
            } label: {
                Label("Add Spot on Photo", systemImage: "bandage")
                    .frame(maxWidth: .infinity, minHeight: actionSize)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!canActivateDirectTool(.spot))
            .accessibilityAddTraits(session.tool == .spot ? .isSelected : [])
        }

        group("Corrections") {
            if asset.develop.spots.isEmpty {
                emptyState("Choose Add Spot, then tap the photo.")
            } else {
                ForEach(asset.develop.spots) { spot in
                    spotRow(spot)
                }
            }
        }

        if let id = session.selectedSpotID,
           asset.develop.spots.contains(where: { $0.id == id }) {
            group("Selected Spot") {
                slider("Size", spotBinding(id, \.size, fallback: 0.02),
                       range: 0.001...0.25, defaultValue: 0.02)
                slider("Feather", spotBinding(id, \.feather, fallback: 0.5),
                       range: 0...1, defaultValue: 0.5)
                slider("Opacity", spotBinding(id, \.opacity, fallback: 1),
                       range: 0...1, defaultValue: 1)
                slider("Source X", spotSourceBinding(id, xAxis: true),
                       range: -1...1, defaultValue: 0)
                slider("Source Y", spotSourceBinding(id, xAxis: false),
                       range: -1...1, defaultValue: 0)
            }
        } else {
            group("Spot Defaults") {
                toolSlider("Size", $session.spotSize, range: 0.001...0.25,
                           defaultValue: 0.02)
                toolSlider("Feather", $session.spotFeather, range: 0...1,
                           defaultValue: 0.5)
                toolSlider("Opacity", $session.spotOpacity, range: 0...1,
                           defaultValue: 1)
            }
        }
    }

    private func spotRow(_ spot: SpotCorrection) -> some View {
        HStack(spacing: 6) {
            Button {
                selectSpot(spot)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(Theme.accent)
                    Text(spotModeName(spot.mode))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: actionSize)
                .padding(.horizontal, 8)
                .background(
                    session.selectedSpotID == spot.id ? Theme.accent.opacity(0.12) : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(spotModeName(spot.mode)) spot correction")
            .accessibilityAddTraits(session.selectedSpotID == spot.id ? .isSelected : [])

            deleteButton("Delete spot correction") { deleteSpot(spot.id) }
        }
    }

    @ViewBuilder
    private var redEyeContent: some View {
        group("Red Eye Tool") {
            Toggle("Pet Eye", isOn: redEyePetBinding)
                .tint(Theme.accent)
                .frame(minHeight: actionSize)

            Button {
                session.selectedRedEyeID = nil
                activateDirectTool(.redEye)
            } label: {
                Label("Draw Eye on Photo", systemImage: "eye")
                    .frame(maxWidth: .infinity, minHeight: actionSize)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(!canActivateDirectTool(.redEye))
            .accessibilityAddTraits(session.tool == .redEye ? .isSelected : [])
        }

        group("Corrections") {
            if asset.develop.redEyes.isEmpty {
                emptyState("Choose Draw Eye, then drag over an eye.")
            } else {
                ForEach(asset.develop.redEyes) { correction in
                    redEyeRow(correction)
                }
            }
        }

        if let id = session.selectedRedEyeID,
           asset.develop.redEyes.contains(where: { $0.id == id }) {
            group("Selected Eye") {
                slider("Radius X", redEyeBinding(id, \.radiusX, fallback: 0.02),
                       range: 0.0001...0.5, defaultValue: 0.02)
                slider("Radius Y", redEyeBinding(id, \.radiusY, fallback: 0.015),
                       range: 0.0001...0.5, defaultValue: 0.015)
                slider("Pupil Size", redEyeBinding(id, \.pupilSize, fallback: 0.5),
                       range: 0...1, defaultValue: 0.5)
                slider("Darken", redEyeBinding(id, \.darken, fallback: 0.5),
                       range: 0...1, defaultValue: 0.5)
            }
        } else {
            group("Eye Defaults") {
                toolSlider("Pupil Size", $session.redEyePupilSize,
                           range: 0...1, defaultValue: 0.5)
                toolSlider("Darken", $session.redEyeDarken,
                           range: 0...1, defaultValue: 0.5)
            }
        }
    }

    private func redEyeRow(_ correction: RedEyeCorrection) -> some View {
        HStack(spacing: 6) {
            Button {
                selectRedEye(correction)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: correction.petEye ? "pawprint" : "eye")
                        .foregroundStyle(correction.petEye ? .green : .red)
                    Text(correction.petEye ? "Pet Eye" : "Red Eye")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: actionSize)
                .padding(.horizontal, 8)
                .background(
                    session.selectedRedEyeID == correction.id
                        ? Theme.accent.opacity(0.12) : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(correction.petEye ? "Pet eye correction" : "Red eye correction")
            .accessibilityAddTraits(
                session.selectedRedEyeID == correction.id ? .isSelected : []
            )

            deleteButton("Delete eye correction") { deleteRedEye(correction.id) }
        }
    }

    // MARK: Curve channel

    enum CurveChannel: String, CaseIterable { case lum = "RGB", red = "R", green = "G", blue = "B" }
    @State private var curveChannel: CurveChannel = .lum

    private var curveBinding: Binding<[CurvePoint]> {
        Binding(
            get: {
                switch curveChannel {
                case .lum:   return asset.develop.toneCurve
                case .red:   return asset.develop.toneCurveRed
                case .green: return asset.develop.toneCurveGreen
                case .blue:  return asset.develop.toneCurveBlue
                }
            },
            set: { points in
                guard developTransaction != nil else { return }
                switch curveChannel {
                case .lum:   asset.develop.toneCurve = points
                case .red:   asset.develop.toneCurveRed = points
                case .green: asset.develop.toneCurveGreen = points
                case .blue:  asset.develop.toneCurveBlue = points
                }
                updateDevelopChange()
            }
        )
    }

    private var channelSelector: some View {
        HStack(spacing: 6) {
            ForEach(CurveChannel.allCases, id: \.self) { ch in
                Button {
                    guard developTransaction == nil else { return }
                    curveChannel = ch
                } label: {
                    Text(ch.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: actionSize)
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
    private func gradeGroup(
        _ title: String,
        hue: Binding<Double>,
        saturation: Binding<Double>,
        luminance: Binding<Double>
    ) -> some View {
        group(title) {
            slider("Hue", hue, range: 0...1, defaultValue: 0, displayScale: 360,
                   accent: Color(hue: hue.wrappedValue, saturation: 0.8, brightness: 0.95))
            slider("Saturation", saturation, range: 0...1, defaultValue: 0,
                   accent: Color(hue: hue.wrappedValue, saturation: 0.8, brightness: 0.95))
            slider("Luminance", luminance, range: -1...1, defaultValue: 0,
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
                          displayScale: Double = 100,
                          accent: Color = Theme.accent) -> some View {
        let trackedValue = Binding(
            get: { value.wrappedValue },
            set: { newValue in
                guard developTransaction != nil else { return }
                value.wrappedValue = newValue
                updateDevelopChange()
            }
        )
        return ScrubSlider(title: title, value: trackedValue, range: range,
                    defaultValue: defaultValue, displayScale: displayScale,
                    accent: accent, onEditingChanged: handleSliderEditing)
    }

    private func toolSlider(
        _ title: String,
        _ value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double,
        displayScale: Double = 100,
        accent: Color = Theme.accent
    ) -> some View {
        ScrubSlider(
            title: title,
            value: value,
            range: range,
            defaultValue: defaultValue,
            displayScale: displayScale,
            accent: accent
        )
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: actionSize, alignment: .leading)
    }

    private func deleteButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
                .frame(width: actionSize, height: actionSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .accessibilityLabel(label)
    }

    private func activateDirectTool(_ tool: DevelopToolSession.Tool) {
        guard developTransaction == nil else { return }
        onActivateTool(tool)
    }

    private func canActivateDirectTool(
        _ tool: DevelopToolSession.Tool,
        selectedMaskID: UUID? = nil
    ) -> Bool {
        DevelopToolAvailability.canActivate(
            tool,
            settings: asset.develop,
            selectedMaskID: selectedMaskID
        )
    }

    private var selectedMask: LocalMask? {
        guard let id = session.selectedMaskID else { return nil }
        return asset.develop.masks.first(where: { $0.id == id })
    }

    private func pointColorBinding(
        _ id: UUID,
        _ keyPath: WritableKeyPath<PointColorAdjustment, Double>,
        fallback: Double = 0
    ) -> Binding<Double> {
        Binding(
            get: {
                asset.develop.pointColors.first(where: { $0.id == id })?[keyPath: keyPath]
                    ?? fallback
            },
            set: { value in
                updatePointColor(id: id) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func maskAdjustmentBinding(
        _ id: UUID,
        _ keyPath: WritableKeyPath<LocalAdjustments, Double>,
        fallback: Double = 0
    ) -> Binding<Double> {
        Binding(
            get: {
                asset.develop.masks.first(where: { $0.id == id })?
                    .adjustments[keyPath: keyPath] ?? fallback
            },
            set: { value in
                updateMask(id: id) { $0.adjustments[keyPath: keyPath] = value }
            }
        )
    }

    private func maskEnabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { asset.develop.masks.first(where: { $0.id == id })?.enabled ?? false },
            set: { enabled in
                performDevelopChange { updateMask(id: id) { $0.enabled = enabled } }
            }
        )
    }

    private func maskInvertedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { asset.develop.masks.first(where: { $0.id == id })?.inverted ?? false },
            set: { inverted in
                performDevelopChange { updateMask(id: id) { $0.inverted = inverted } }
            }
        )
    }

    private enum LinearField { case startX, startY, endX, endY }

    private func linearBinding(_ maskID: UUID, _ componentID: UUID, _ field: LinearField) -> Binding<Double> {
        Binding(
            get: {
                guard let component = component(maskID: maskID, componentID: componentID),
                      case let .linear(start, end) = component.shape else { return 0 }
                switch field {
                case .startX: return start.x
                case .startY: return start.y
                case .endX: return end.x
                case .endY: return end.y
                }
            },
            set: { value in
                updateComponent(maskID: maskID, componentID: componentID) { component in
                    guard case let .linear(start, end) = component.shape else { return }
                    switch field {
                    case .startX:
                        component.shape = .linear(start: NormalizedPoint(x: value, y: start.y), end: end)
                    case .startY:
                        component.shape = .linear(start: NormalizedPoint(x: start.x, y: value), end: end)
                    case .endX:
                        component.shape = .linear(start: start, end: NormalizedPoint(x: value, y: end.y))
                    case .endY:
                        component.shape = .linear(start: start, end: NormalizedPoint(x: end.x, y: value))
                    }
                }
            }
        )
    }

    private enum RadialField { case radiusX, radiusY, angle, feather }

    private func radialBinding(_ maskID: UUID, _ componentID: UUID, _ field: RadialField) -> Binding<Double> {
        Binding(
            get: {
                guard let component = component(maskID: maskID, componentID: componentID),
                      case let .radial(_, radiusX, radiusY, angle, feather, _) = component.shape
                else { return 0 }
                switch field {
                case .radiusX: return radiusX
                case .radiusY: return radiusY
                case .angle: return angle
                case .feather: return feather
                }
            },
            set: { value in
                updateComponent(maskID: maskID, componentID: componentID) { component in
                    guard case let .radial(center, radiusX, radiusY, angle, feather, inverted) = component.shape
                    else { return }
                    component.shape = .radial(
                        center: center,
                        radiusX: field == .radiusX ? value : radiusX,
                        radiusY: field == .radiusY ? value : radiusY,
                        angle: field == .angle ? value : angle,
                        feather: field == .feather ? value : feather,
                        inverted: inverted
                    )
                }
            }
        )
    }

    private func radialInvertedBinding(_ maskID: UUID, _ componentID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                guard let component = component(maskID: maskID, componentID: componentID),
                      case let .radial(_, _, _, _, _, inverted) = component.shape else { return false }
                return inverted
            },
            set: { inverted in
                performDevelopChange {
                    updateComponent(maskID: maskID, componentID: componentID) { component in
                        guard case let .radial(center, radiusX, radiusY, angle, feather, _) = component.shape
                        else { return }
                        component.shape = .radial(
                            center: center,
                            radiusX: radiusX,
                            radiusY: radiusY,
                            angle: angle,
                            feather: feather,
                            inverted: inverted
                        )
                    }
                }
            }
        )
    }

    private var spotModeRawBinding: Binding<String> {
        Binding(
            get: {
                if let id = session.selectedSpotID,
                   let spot = asset.develop.spots.first(where: { $0.id == id }) {
                    return spot.mode.rawValue
                }
                return session.spotMode.rawValue
            },
            set: { rawValue in
                guard let mode = SpotMode(rawValue: rawValue) else { return }
                session.spotMode = mode
                if let id = session.selectedSpotID,
                   asset.develop.spots.contains(where: { $0.id == id }) {
                    performDevelopChange { updateSpot(id: id) { $0.mode = mode } }
                }
            }
        )
    }

    private func spotBinding(
        _ id: UUID,
        _ keyPath: WritableKeyPath<SpotCorrection, Double>,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { asset.develop.spots.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback },
            set: { value in updateSpot(id: id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func spotSourceBinding(_ id: UUID, xAxis: Bool) -> Binding<Double> {
        Binding(
            get: {
                guard let offset = asset.develop.spots.first(where: { $0.id == id })?.sourceOffset else {
                    return 0
                }
                return xAxis ? offset.dx : offset.dy
            },
            set: { value in
                updateSpot(id: id) { spot in
                    let offset = spot.sourceOffset ?? NormalizedVector(dx: 0, dy: 0)
                    spot.sourceOffset = NormalizedVector(
                        dx: xAxis ? value : offset.dx,
                        dy: xAxis ? offset.dy : value
                    )
                }
            }
        )
    }

    private var redEyePetBinding: Binding<Bool> {
        Binding(
            get: {
                if let id = session.selectedRedEyeID,
                   let correction = asset.develop.redEyes.first(where: { $0.id == id }) {
                    return correction.petEye
                }
                return session.redEyePetMode
            },
            set: { petEye in
                session.redEyePetMode = petEye
                if let id = session.selectedRedEyeID,
                   asset.develop.redEyes.contains(where: { $0.id == id }) {
                    performDevelopChange {
                        updateRedEye(id: id) { correction in
                            correction.petEye = petEye
                            if !petEye { correction.catchlight = nil }
                        }
                    }
                }
            }
        )
    }

    private func redEyeBinding(
        _ id: UUID,
        _ keyPath: WritableKeyPath<RedEyeCorrection, Double>,
        fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: {
                asset.develop.redEyes.first(where: { $0.id == id })?[keyPath: keyPath]
                    ?? fallback
            },
            set: { value in updateRedEye(id: id) { $0[keyPath: keyPath] = value } }
        )
    }

    private func selectMask(_ mask: LocalMask) {
        session.selectedMaskID = mask.id
        if let stroke = mask.components.compactMap({ component -> BrushStroke? in
            guard case let .brush(strokes) = component.shape else { return nil }
            return strokes.last
        }).last {
            session.brushSize = stroke.size
            session.brushFeather = stroke.feather
            session.brushFlow = stroke.flow
            session.brushDensity = stroke.density
            session.brushErase = stroke.erase
        }
    }

    private func selectSpot(_ spot: SpotCorrection) {
        session.selectedSpotID = spot.id
        session.spotMode = spot.mode
        session.spotSize = spot.size
        session.spotFeather = spot.feather
        session.spotOpacity = spot.opacity
    }

    private func selectRedEye(_ correction: RedEyeCorrection) {
        session.selectedRedEyeID = correction.id
        session.redEyePetMode = correction.petEye
        session.redEyePupilSize = correction.pupilSize
        session.redEyeDarken = correction.darken
    }

    private func deletePointColor(_ id: UUID) {
        performDevelopChange {
            var settings = asset.develop
            settings.pointColors.removeAll { $0.id == id }
            asset.develop = settings
        }
        if session.selectedPointColorID == id {
            session.selectedPointColorID = asset.develop.pointColors.first?.id
        }
    }

    private func deleteMask(_ id: UUID) {
        performDevelopChange {
            var settings = asset.develop
            settings.masks.removeAll { $0.id == id }
            asset.develop = settings
        }
        if session.selectedMaskID == id { session.selectedMaskID = asset.develop.masks.first?.id }
    }

    private func deleteSpot(_ id: UUID) {
        performDevelopChange {
            var settings = asset.develop
            settings.spots.removeAll { $0.id == id }
            asset.develop = settings
        }
        if session.selectedSpotID == id { session.selectedSpotID = asset.develop.spots.first?.id }
    }

    private func deleteRedEye(_ id: UUID) {
        performDevelopChange {
            var settings = asset.develop
            settings.redEyes.removeAll { $0.id == id }
            asset.develop = settings
        }
        if session.selectedRedEyeID == id { session.selectedRedEyeID = asset.develop.redEyes.first?.id }
    }

    private func updatePointColor(id: UUID, change: (inout PointColorAdjustment) -> Void) {
        var settings = asset.develop
        guard let index = settings.pointColors.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.pointColors[index])
        asset.develop = settings
    }

    private func updateMask(id: UUID, change: (inout LocalMask) -> Void) {
        var settings = asset.develop
        guard let index = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.masks[index])
        asset.develop = settings
    }

    private func component(maskID: UUID, componentID: UUID) -> MaskComponent? {
        asset.develop.masks.first(where: { $0.id == maskID })?
            .components.first(where: { $0.id == componentID })
    }

    private func updateComponent(
        maskID: UUID,
        componentID: UUID,
        change: (inout MaskComponent) -> Void
    ) {
        updateMask(id: maskID) { mask in
            guard let index = mask.components.firstIndex(where: { $0.id == componentID }) else { return }
            change(&mask.components[index])
        }
    }

    private func updateSpot(id: UUID, change: (inout SpotCorrection) -> Void) {
        var settings = asset.develop
        guard let index = settings.spots.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.spots[index])
        asset.develop = settings
    }

    private func updateRedEye(id: UUID, change: (inout RedEyeCorrection) -> Void) {
        var settings = asset.develop
        guard let index = settings.redEyes.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.redEyes[index])
        asset.develop = settings
    }

    private func maskShapeName(_ mask: LocalMask) -> String {
        guard let shape = mask.components.first?.shape else { return "Empty" }
        switch shape {
        case .brush: return "Brush"
        case .linear: return "Linear Gradient"
        case .radial: return "Radial Gradient"
        }
    }

    private func maskShapeIcon(_ mask: LocalMask) -> String {
        guard let shape = mask.components.first?.shape else { return "circle.dashed" }
        switch shape {
        case .brush: return "paintbrush.pointed"
        case .linear: return "rectangle.split.3x1"
        case .radial: return "circle.dashed"
        }
    }

    private func spotModeName(_ mode: SpotMode) -> String {
        switch mode {
        case .remove: return "Remove"
        case .heal: return "Heal"
        case .clone: return "Clone"
        }
    }

    // MARK: Color Mixer band selector

    private var bandSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(0..<ColorMix.bandCount, id: \.self) { b in
                    let edited = asset.develop.colorMix.hue[b] != 0
                        || asset.develop.colorMix.saturation[b] != 0
                        || asset.develop.colorMix.luminance[b] != 0
                    Button {
                        mixBand = b
                    } label: {
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
                            .frame(width: actionSize, height: actionSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.bandNames[b])
                    .accessibilityAddTraits(mixBand == b ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var blackWhiteBandSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(BlackWhiteBand.allCases) { band in
                    Button {
                        blackWhiteBand = band
                    } label: {
                        Circle()
                            .fill(band.color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle().strokeBorder(.white, lineWidth: blackWhiteBand == band ? 2 : 0)
                            )
                            .overlay(alignment: .bottomTrailing) {
                                if blackWhiteValue(for: band) != 0 {
                                    Circle().fill(.white).frame(width: 5, height: 5)
                                }
                            }
                            .frame(width: actionSize, height: actionSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(band.rawValue)
                    .accessibilityLabel("\(band.rawValue) black and white mix")
                    .accessibilityAddTraits(blackWhiteBand == band ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func blackWhiteBinding(for band: BlackWhiteBand) -> Binding<Double> {
        switch band {
        case .red: return $asset.develop.bwRed
        case .orange: return $asset.develop.bwOrange
        case .yellow: return $asset.develop.bwYellow
        case .green: return $asset.develop.bwGreen
        case .aqua: return $asset.develop.bwAqua
        case .blue: return $asset.develop.bwBlue
        case .purple: return $asset.develop.bwPurple
        case .magenta: return $asset.develop.bwMagenta
        }
    }

    private func blackWhiteValue(for band: BlackWhiteBand) -> Double {
        blackWhiteBinding(for: band).wrappedValue
    }

    private var blackWhiteBinding: Binding<Bool> {
        Binding(
            get: { asset.develop.blackWhite },
            set: { enabled in
                performDevelopChange { asset.develop.blackWhite = enabled }
            }
        )
    }

    private func handleSliderEditing(_ editing: Bool, owner: UUID) -> Bool {
        if editing {
            return beginDevelopChange(owner: owner)
        } else {
            return endDevelopChange(owner: owner)
        }
    }

    @discardableResult
    private func beginDevelopChange(owner: UUID) -> Bool {
        if developTransactionOwner == owner, developTransaction != nil { return true }
        guard developTransaction == nil, developTransactionOwner == nil else { return false }
        guard let transaction = history.beginChange(
            for: asset.id,
            current: asset.develop
        ) else { return false }
        developTransaction = transaction
        developTransactionOwner = owner
        return true
    }

    private func updateDevelopChange() {
        guard let developTransaction else { return }
        history.updateChange(developTransaction, current: asset.develop)
    }

    @discardableResult
    private func endDevelopChange(owner: UUID) -> Bool {
        guard developTransactionOwner == owner,
              let transaction = developTransaction else { return false }
        developTransaction = nil
        developTransactionOwner = nil
        return history.endChange(transaction, current: asset.develop)
    }

    private func endActiveDevelopChange() {
        guard let transaction = developTransaction else { return }
        developTransaction = nil
        developTransactionOwner = nil
        history.endChange(transaction, current: asset.develop)
    }

    private func performDevelopChange(_ change: () -> Void) {
        guard developTransaction == nil else { return }
        guard let transaction = history.beginChange(
            for: asset.id,
            current: asset.develop
        ) else { return }
        change()
        history.updateChange(transaction, current: asset.develop)
        history.endChange(transaction)
    }

    private func undo() {
        guard let settings = history.undo(for: asset.id, current: asset.develop) else { return }
        asset.develop = settings
    }

    private func redo() {
        guard let settings = history.redo(for: asset.id, current: asset.develop) else { return }
        asset.develop = settings
    }

    private var actionSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    private var tabItemWidth: CGFloat {
        #if os(iOS)
        44
        #else
        37
        #endif
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
                    withAnimation { performDevelopChange { asset.develop.reset() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every develop setting. Your original file is not affected.")
            }
            .frame(minHeight: actionSize)
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
