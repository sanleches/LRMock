//
//  CropView.swift
//  RawLight
//
//  Interactive crop + geometry editor shown as a mode inside the loupe. Renders
//  the image with all adjustments EXCEPT the crop (so you frame against the full
//  result), overlaid with a draggable crop rectangle. Includes aspect presets,
//  straighten, rotate 90°, and flips. Writes straight into the asset's
//  `DevelopSettings` geometry fields.
//

import SwiftUI

struct CropView: View {
    @Bindable var asset: ImageAsset
    var onDone: () -> Void

    @State private var renderedAspect: Double?
    @State private var aspect: AspectPreset = .free

    enum AspectPreset: String, CaseIterable, Identifiable {
        case free = "Free", square = "1:1", p45 = "4:5", p23 = "2:3", p34 = "3:4", p169 = "16:9"
        var id: String { rawValue }
        /// width / height, or nil for free.
        var ratio: Double? {
            switch self {
            case .free: return nil
            case .square: return 1
            case .p45: return 4.0 / 5
            case .p23: return 2.0 / 3
            case .p34: return 3.0 / 4
            case .p169: return 16.0 / 9
            }
        }
    }

    /// Settings used for the backdrop render: everything but the crop.
    private var backdropSettings: DevelopSettings {
        var s = asset.develop
        s.cropX = 0; s.cropY = 0; s.cropW = 1; s.cropH = 1
        return s
    }

    private var imageAspect: Double {
        renderedAspect ?? asset.aspectRatio
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.separator)

            GeometryReader { geo in
                let frame = fittedRect(in: geo.size)
                ZStack {
                    Theme.canvas
                    DevelopPreview(asset: asset, settings: backdropSettings) { cg in
                        renderedAspect = Double(cg.width) / Double(cg.height)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)

                    CropRectangle(
                        cropX: $asset.develop.cropX, cropY: $asset.develop.cropY,
                        cropW: $asset.develop.cropW, cropH: $asset.develop.cropH,
                        imageFrame: frame,
                        lockedRatio: aspect.ratio,
                        imageAspect: imageAspect
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            Divider().overlay(Theme.separator)
            controls
        }
        .background(Theme.canvas)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button(action: resetGeometry) {
                Text("Reset")
                    .frame(minWidth: controlSize, minHeight: controlSize, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .tint(Theme.accent)
            .help("Reset Crop and Geometry")
            Spacer()
            Text("Crop & Rotate").font(.headline).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button(action: onDone) {
                Text("Done")
                    .frame(minWidth: controlSize, minHeight: controlSize, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .tint(Theme.accent)
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, toolbarVerticalPadding)
        .background(Theme.panel)
    }

    // MARK: Bottom controls

    private var controls: some View {
        VStack(spacing: 12) {
            // Aspect presets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AspectPreset.allCases) { preset in
                        Button {
                            aspect = preset
                            applyAspect(preset)
                        } label: {
                            Text(preset.rawValue)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14)
                                .frame(minHeight: controlSize)
                                .background(aspect == preset ? Theme.accent : Theme.surface,
                                            in: Capsule())
                                .foregroundStyle(aspect == preset ? .white : Theme.textSecondary)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("\(preset.rawValue) Aspect")
                        .accessibilityLabel("\(preset.rawValue) crop aspect")
                        .accessibilityAddTraits(aspect == preset ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }

            // Straighten
            HStack(spacing: 10) {
                Image(systemName: "angle").foregroundStyle(Theme.textSecondary)
                Slider(value: $asset.develop.straighten, in: -45...45)
                    .tint(Theme.accent)
                    .frame(minHeight: controlSize)
                    .accessibilityLabel("Straighten")
                    .accessibilityValue("\(Int(asset.develop.straighten)) degrees")
                Text("\(Int(asset.develop.straighten))°")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 34)
            }
            .padding(.horizontal, 16)

            // Rotate / flip
            HStack(spacing: 22) {
                iconButton("rotate.left", label: "Rotate Left") {
                    asset.develop.rotationQuarterTurns -= 1
                }
                iconButton("rotate.right", label: "Rotate Right") {
                    asset.develop.rotationQuarterTurns += 1
                }
                iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right",
                           label: "Flip Horizontal") {
                    asset.develop.flipH.toggle()
                }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down",
                           label: "Flip Vertical") {
                    asset.develop.flipV.toggle()
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.vertical, 12)
        .background(Theme.panel)
    }

    private func iconButton(
        _ system: String,
        label: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: controlSize, height: controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Geometry helpers

    private func fittedRect(in size: CGSize) -> CGRect {
        let a = imageAspect
        let areaAspect = size.width / size.height
        var w = size.width, h = size.height
        if a > areaAspect { h = w / a } else { w = h * a }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func applyAspect(_ preset: AspectPreset) {
        guard let ratio = preset.ratio else { return }
        // Normalised crop w/h so that (cropW*W)/(cropH*H) == ratio.
        var cw = 1.0, ch = 1.0
        let normRatio = ratio / imageAspect   // desired cropW/cropH
        if normRatio >= 1 { ch = 1 / normRatio } else { cw = normRatio }
        asset.develop.cropW = cw
        asset.develop.cropH = ch
        asset.develop.cropX = (1 - cw) / 2
        asset.develop.cropY = (1 - ch) / 2
    }

    private func resetGeometry() {
        asset.develop.cropX = 0; asset.develop.cropY = 0
        asset.develop.cropW = 1; asset.develop.cropH = 1
        asset.develop.straighten = 0
        asset.develop.geometryVertical = 0; asset.develop.geometryHorizontal = 0
        asset.develop.geometryAspect = 0; asset.develop.geometryScale = 1
        asset.develop.geometryOffsetX = 0; asset.develop.geometryOffsetY = 0
        asset.develop.flipH = false; asset.develop.flipV = false
        asset.develop.rotationQuarterTurns = 0
        aspect = .free
    }

    private var controlSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    private var toolbarVerticalPadding: CGFloat {
        #if os(iOS)
        2
        #else
        8
        #endif
    }
}

/// The draggable crop rectangle with four corner handles and an interior move.
private struct CropRectangle: View {
    @Binding var cropX: Double
    @Binding var cropY: Double
    @Binding var cropW: Double
    @Binding var cropH: Double
    let imageFrame: CGRect
    let lockedRatio: Double?
    let imageAspect: Double

    private static let space = "cropCoordinateSpace"
    @State private var moveStart: (x: Double, y: Double)?

    var body: some View {
        let rect = pixelRect
        ZStack(alignment: .topLeading) {
            // Dim outside the crop.
            Rectangle().fill(.black.opacity(0.5))
                .reverseMask { Rectangle().frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY) }
                .allowsHitTesting(false)

            // Border.
            Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)

            // Interior move.
            Color.clear
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .contentShape(Rectangle())
                .gesture(moveGesture)

            // Corner handles (large invisible hit target around a small dot).
            ForEach(Corner.allCases, id: \.self) { corner in
                handle
                    .position(cornerPoint(corner, in: rect))
                    .gesture(cornerGesture(corner))
            }
        }
        .frame(width: imageFrame.width, height: imageFrame.height)
        .coordinateSpace(name: Self.space)
        .position(x: imageFrame.midX, y: imageFrame.midY)
    }

    private var handle: some View {
        ZStack {
            Color.clear.frame(width: 44, height: 44).contentShape(Rectangle())
            Circle().fill(.white).frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.4), radius: 2)
        }
    }

    enum Corner: CaseIterable { case tl, tr, bl, br }

    private var pixelRect: CGRect {
        CGRect(x: cropX * imageFrame.width, y: cropY * imageFrame.height,
               width: cropW * imageFrame.width, height: cropH * imageFrame.height)
    }

    private func cornerPoint(_ c: Corner, in r: CGRect) -> CGPoint {
        switch c {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    // Move: capture the crop origin at gesture start and apply the translation
    // delta, so the rectangle tracks the pointer 1:1 without drift.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if moveStart == nil { moveStart = (cropX, cropY) }
                guard let s = moveStart else { return }
                let dx = g.translation.width / imageFrame.width
                let dy = g.translation.height / imageFrame.height
                cropX = min(max(0, s.x + dx), 1 - cropW)
                cropY = min(max(0, s.y + dy), 1 - cropH)
            }
            .onEnded { _ in moveStart = nil }
    }

    // Corner: read the pointer's absolute position in the image coordinate
    // space so the handle sits exactly under the finger/cursor.
    private func cornerGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { g in
                let nx = min(max(0, g.location.x / imageFrame.width), 1)
                let ny = min(max(0, g.location.y / imageFrame.height), 1)
                var x0 = cropX, y0 = cropY, x1 = cropX + cropW, y1 = cropY + cropH
                switch corner {
                case .tl: x0 = min(nx, x1 - 0.05); y0 = min(ny, y1 - 0.05)
                case .tr: x1 = max(nx, x0 + 0.05); y0 = min(ny, y1 - 0.05)
                case .bl: x0 = min(nx, x1 - 0.05); y1 = max(ny, y0 + 0.05)
                case .br: x1 = max(nx, x0 + 0.05); y1 = max(ny, y0 + 0.05)
                }
                cropX = x0; cropY = y0; cropW = x1 - x0; cropH = y1 - y0
            }
    }
}

// Inverse mask helper (cut a hole in a view).
private extension View {
    @ViewBuilder
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle().overlay { mask().blendMode(.destinationOut) }
        }
    }
}
