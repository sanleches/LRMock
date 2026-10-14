//
//  CoreImageAdjustments.swift
//  RawLight
//
//  Core Image building blocks used by `CoreImagePipeline`: RAW-aware decode plus
//  the full develop adjustment chain.
//
//  This is the single source of truth for the normalised-units → CI-parameter
//  mapping. RAW inputs are developed by `RawNativeDecoder` (CIRAWFilter) first,
//  so `includeBasics` lets the chain skip the operations already done natively.
//

import CoreImage
import CoreImage.CIFilterBuiltins

nonisolated enum CoreImageAdjustments {

    // MARK: Decode

    typealias NativeDecoder = @Sendable (RawNativeDecoder.Request) -> CIImage?

    /// Result of decoding: the baseline image plus whether it came from the
    /// RAW-native engine (which already consumed exposure/WB/NR/sharpen).
    struct Decoded {
        var image: CIImage
        var isRAW: Bool
    }

    struct OpticsParameters: Equatable, Sendable {
        let distortionScale: Double
        let vignetteIntensity: Double
        let redChannelScale: Double
        let blueChannelScale: Double
    }

    struct GrainParameters: Equatable, Sendable {
        let coarseScale: Double
        let fineScale: Double
        let fineMix: Double
        let opacity: Double
    }

    struct VignetteGeometry: Equatable, Sendable {
        let innerRect: CGRect
        let cornerRadius: Double
        let blurRadius: Double
    }

    struct PerspectiveCorners: Equatable, Sendable {
        let topLeft: CGPoint
        let topRight: CGPoint
        let bottomRight: CGPoint
        let bottomLeft: CGPoint
    }

    private struct ProjectiveTransform {
        let a: CGFloat
        let b: CGFloat
        let c: CGFloat
        let d: CGFloat
        let e: CGFloat
        let f: CGFloat
        let g: CGFloat
        let h: CGFloat
        let i: CGFloat

        func applying(_ point: CGPoint) -> CGPoint? {
            let denominator = g * point.x + h * point.y + i
            guard denominator.isFinite, abs(denominator) > .ulpOfOne else { return nil }
            let x = (a * point.x + b * point.y + c) / denominator
            let y = (d * point.x + e * point.y + f) / denominator
            guard x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }

        func inverted() -> ProjectiveTransform? {
            let determinant = a * (e * i - f * h)
                - b * (d * i - f * g)
                + c * (d * h - e * g)
            guard determinant.isFinite, abs(determinant) > .ulpOfOne else { return nil }
            return ProjectiveTransform(
                a: (e * i - f * h) / determinant,
                b: (c * h - b * i) / determinant,
                c: (b * f - c * e) / determinant,
                d: (f * g - d * i) / determinant,
                e: (a * i - c * g) / determinant,
                f: (c * d - a * f) / determinant,
                g: (d * h - e * g) / determinant,
                h: (b * g - a * h) / determinant,
                i: (a * e - b * d) / determinant
            )
        }

        static func unitSquareToQuadrilateral(
            bottomLeft p0: CGPoint,
            bottomRight p1: CGPoint,
            topRight p2: CGPoint,
            topLeft p3: CGPoint
        ) -> ProjectiveTransform? {
            let dx1 = p1.x - p2.x
            let dx2 = p3.x - p2.x
            let dx3 = p0.x - p1.x + p2.x - p3.x
            let dy1 = p1.y - p2.y
            let dy2 = p3.y - p2.y
            let dy3 = p0.y - p1.y + p2.y - p3.y
            if abs(dx3) <= .ulpOfOne, abs(dy3) <= .ulpOfOne {
                return ProjectiveTransform(
                    a: p1.x - p0.x,
                    b: p3.x - p0.x,
                    c: p0.x,
                    d: p1.y - p0.y,
                    e: p3.y - p0.y,
                    f: p0.y,
                    g: 0,
                    h: 0,
                    i: 1
                )
            }
            let denominator = dx1 * dy2 - dx2 * dy1
            guard denominator.isFinite, abs(denominator) > .ulpOfOne else { return nil }
            let g = (dx3 * dy2 - dx2 * dy3) / denominator
            let h = (dx1 * dy3 - dx3 * dy1) / denominator
            return ProjectiveTransform(
                a: p1.x - p0.x + g * p1.x,
                b: p3.x - p0.x + h * p3.x,
                c: p0.x,
                d: p1.y - p0.y + g * p1.y,
                e: p3.y - p0.y + h * p3.y,
                f: p0.y,
                g: g,
                h: h,
                i: 1
            )
        }
    }

    static func opticsParameters(for s: DevelopSettings) -> OpticsParameters {
        let distortion = signedUnit(s.opticsDistortion)
        let vignette = signedUnit(s.opticsVignetting)
        let distortionProfile = bounded(s.opticsProfileDistortion, 0...2, fallback: 1)
        let vignetteProfile = bounded(s.opticsProfileVignetting, 0...2, fallback: 1)
        return OpticsParameters(
            distortionScale: min(0.6, max(-0.6, -0.34 * distortion * distortionProfile)),
            vignetteIntensity: min(2, max(-2, -1.25 * vignette * vignetteProfile)),
            redChannelScale: 1 - signedUnit(s.opticsCARed) * 0.004,
            blueChannelScale: 1 - signedUnit(s.opticsCABlue) * 0.004
        )
    }

    static func grainParameters(amount: Double, size: Double, roughness: Double) -> GrainParameters {
        let amount = unit(amount)
        let size = unit(size)
        let roughness = unit(roughness)
        let coarse = 0.7 + size * 3.3
        return GrainParameters(
            coarseScale: coarse,
            fineScale: coarse * (0.28 + roughness * 0.3),
            fineMix: roughness * 0.75,
            opacity: min(0.5, amount * 0.42)
        )
    }

    static func vignetteGeometry(
        extent: CGRect,
        midpoint: Double,
        roundness: Double,
        feather: Double
    ) -> VignetteGeometry {
        let short = max(1, min(extent.width, extent.height))
        let inset = short * (0.32 - unit(midpoint) * 0.27)
        let inner = extent.insetBy(dx: min(inset, extent.width * 0.45),
                                   dy: min(inset, extent.height * 0.45))
        let rounded = (signedUnit(roundness) + 1) * 0.5
        return VignetteGeometry(
            innerRect: inner,
            cornerRadius: min(inner.width, inner.height) * 0.5 * rounded,
            blurRadius: min(256, short * (0.015 + unit(feather) * 0.18))
        )
    }

    static func geometryPerspectiveCorners(
        extent: CGRect,
        vertical: Double,
        horizontal: Double
    ) -> PerspectiveCorners {
        let verticalInset = signedUnit(vertical) * extent.width * 0.18
        let horizontalInset = signedUnit(horizontal) * extent.height * 0.18
        return PerspectiveCorners(
            topLeft: CGPoint(x: extent.minX + verticalInset,
                             y: extent.maxY - horizontalInset),
            topRight: CGPoint(x: extent.maxX - verticalInset,
                              y: extent.maxY + horizontalInset),
            bottomRight: CGPoint(x: extent.maxX + verticalInset,
                                 y: extent.minY - horizontalInset),
            bottomLeft: CGPoint(x: extent.minX - verticalInset,
                                y: extent.minY + horizontalInset)
        )
    }

    /// Decodes `url`, developing RAW inputs through `CIRAWFilter` (high fidelity)
    /// and loading non-RAW inputs directly.
    static func decode(
        _ url: URL,
        settings: DevelopSettings,
        maxPixelSize: Int?,
        quality: PreviewRenderQuality,
        intent: RawNativeDecoder.RenderIntent = .display,
        nativeDecoder: NativeDecoder = { RawNativeDecoder.developedImage(request: $0) }
    ) throws -> Decoded {
        let request = RawNativeDecoder.Request(
            url: url,
            settings: settings,
            maxPixelSize: maxPixelSize,
            quality: quality,
            intent: intent
        )
        if let raw = nativeDecoder(request) {
            return Decoded(image: raw, isRAW: true)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw RawPipelineError.decodeFailed
        }
        return Decoded(image: image, isRAW: false)
    }

    // MARK: Adjustment chain

    /// Applies the colour stages that precede Point Color. This is also the
    /// source image for the Point Color sampler.
    /// - Parameter includeBasics: apply exposure/white balance here (true for
    ///   non-RAW; false for RAW, where `CIRAWFilter` already did them).
    static func applyPointColorInput(
        to input: CIImage,
        settings s: DevelopSettings,
        includeBasics: Bool,
        quality: PreviewRenderQuality
    ) -> CIImage {
        var image = input
        let extent = input.extent

        // 1. Exposure — normalised ±1 → ±2.5 EV. (RAW: done natively.)
        if includeBasics, s.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(s.exposure * 2.5)
            image = f.outputImage ?? image
        }

        // 2. White balance. (RAW: done natively from its as-shot neutral.)
        if includeBasics, s.temperature != 0 || s.tint != 0 {
            let baseline = WhiteBalanceMapping.renderedBaseline
            let neutral = WhiteBalanceMapping.adjustedNeutral(
                baseline: baseline,
                temperature: s.temperature,
                tint: s.tint
            )
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            // Vary the source neutral, as CIRAWFilter does, while adapting back
            // to the rendered-image baseline. This keeps both slider directions.
            f.neutral = CIVector(x: neutral.kelvin, y: neutral.tint)
            f.targetNeutral = CIVector(x: baseline.kelvin, y: baseline.tint)
            image = f.outputImage ?? image
        }

        // 3. Lens-space corrections and calibration, before creative colour.
        image = applyOptics(to: image, settings: s, quality: quality)

        if let cube = ColorCubeEngine.calibrationCube(
            shadowsTint: s.calibrationShadowsTint,
            redHue: s.calibrationRedHue, redSat: s.calibrationRedSat,
            greenHue: s.calibrationGreenHue, greenSat: s.calibrationGreenSat,
            blueHue: s.calibrationBlueHue, blueSat: s.calibrationBlueSat
        ) {
            image = applyCube(cube, to: image)
        }

        // 4. Foundation, parametric and point curves in one monotone LUT pass.
        let basicToneActive = s.highlights != 0 || s.shadows != 0
            || s.whites != 0 || s.blacks != 0
        let parametricActive = s.curveHighlights != 0 || s.curveLights != 0
            || s.curveDarks != 0 || s.curveShadows != 0
        let pointCurvesActive = !s.isCurveLinear(s.toneCurve) || !s.isCurveLinear(s.toneCurveRed)
            || !s.isCurveLinear(s.toneCurveGreen) || !s.isCurveLinear(s.toneCurveBlue)
        let curvesActive = basicToneActive || parametricActive || pointCurvesActive
        if curvesActive {
            let beforeCurve = image
            let lut = ToneCurveLUT.channelLUT(
                master: s.toneCurve, red: s.toneCurveRed,
                green: s.toneCurveGreen, blue: s.toneCurveBlue, sampleCount: 256,
                highlights: s.highlights, shadows: s.shadows,
                whites: s.whites, blacks: s.blacks,
                curveHighlights: s.curveHighlights, curveLights: s.curveLights,
                curveDarks: s.curveDarks, curveShadows: s.curveShadows,
                splitShadows: s.curveSplitShadows, splitMid: s.curveSplitMid,
                splitHighlights: s.curveSplitHighlights)
            let f = CIFilter.colorCurves()
            f.inputImage = image
            f.curvesData = lut.withUnsafeBytes { Data($0) }
            f.curvesDomain = CIVector(x: 0, y: 1)
            f.colorSpace = CGColorSpaceCreateDeviceRGB()
            image = f.outputImage ?? image

            let preservation = ToneCurveLUT.saturationPreservationAmount(
                refine: s.curveRefineSaturation
            )
            if preservation > 0 {
                let preserve = CIFilter.saturationBlendMode()
                preserve.inputImage = beforeCurve
                preserve.backgroundImage = image
                if let preserved = preserve.outputImage {
                    let mix = CIFilter.dissolveTransition()
                    mix.inputImage = image
                    mix.targetImage = preserved
                    mix.time = Float(preservation)
                    image = (mix.outputImage ?? image).cropped(to: extent)
                }
            }
        }

        // 5. RawLight Color profile strength. The default 1.0 is an exact no-op.
        if let cube = ColorCubeEngine.profileCube(amount: s.profileAmount) {
            image = applyCube(cube, to: image)
        }

        // 6. Eight-band B&W mixer.
        if s.blackWhite {
            let cube = ColorCubeEngine.blackAndWhiteCube(mix: [
                s.bwRed, s.bwOrange, s.bwYellow, s.bwGreen,
                s.bwAqua, s.bwBlue, s.bwPurple, s.bwMagenta,
            ])
            image = applyCube(cube, to: image)
        }

        // 7. Contrast + saturation.
        if s.contrast != 0 || s.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1 + s.contrast * 0.5)
            f.saturation = Float(s.blackWhite ? 0 : 1 + s.saturation)
            f.brightness = 0
            image = f.outputImage ?? image
        }

        // 6b. Color Mixer (8-band HSL) via a GPU colour-cube LUT.
        if !s.blackWhite, let cube = ColorCubeEngine.hslCube(for: s.colorMix) {
            image = applyCube(cube, to: image)
        }

        return image
    }

    /// Applies the complete develop chain after decode.
    static func apply(
        to input: CIImage,
        settings s: DevelopSettings,
        includeBasics: Bool,
        quality: PreviewRenderQuality
    ) -> CIImage {
        let selectivePaths = DevelopSettings.boundedSelectivePaths(
            masks: s.masks,
            spots: s.spots
        )
        var image = applyPointColorInput(
            to: input,
            settings: s,
            includeBasics: includeBasics,
            quality: quality
        )
        let extent = input.extent

        // 6c. Point Color, after the global mixer and before grading.
        if let cube = ColorCubeEngine.pointColorCube(for: s.pointColors) {
            image = applyPointColorCube(cube, to: image)
        }

        // 6d. Color Grading (three ranges plus global wheel) via a cached cube.
        if let cube = ColorCubeEngine.gradingCube(for: s.grade) {
            image = applyCube(cube, to: image)
        }

        // 7. Dehaze — approximate: lift contrast + saturation, deepen blacks.
        if s.dehaze != 0 {
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.contrast = Float(1 + s.dehaze * 0.35)
            cc.saturation = Float(1 + s.dehaze * 0.25)
            cc.brightness = Float(-s.dehaze * 0.03)
            image = cc.outputImage ?? image
        }

        // 8. Clarity — midtone local contrast via a wide-radius unsharp mask.
        if s.clarity != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = quality == .interactive ? 14 : 40
            f.intensity = Float(s.clarity * 0.8)
            image = f.outputImage ?? image
        }

        // 9. Texture — fine local contrast via a small-radius unsharp mask.
        if s.texture != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = 2.5
            f.intensity = Float(s.texture * 0.7)
            image = f.outputImage ?? image
        }

        // 10. Vibrance.
        if s.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(s.vibrance)
            image = f.outputImage ?? image
        }

        // 11. Noise reduction. RAW gets a reduced post pass as well so radius,
        // detail, contrast and colour smoothness have the same visible semantics.
        if quality == .settled, s.noiseReduction > 0 || s.colorNoiseReduction > 0 {
            image = applyNoiseReduction(to: image, settings: s, includeBasics: includeBasics)
        }

        // 12. Sharpening. Interactive renders use the cheap base pass; the
        // settled pass adds fine detail and edge masking.
        if s.sharpness > 0 {
            image = applySharpening(
                to: image, settings: s, includeBasics: includeBasics, quality: quality
            )
        }

        image = image.cropped(to: image.extent.isInfinite ? extent : image.extent)

        // 13. Spatial records live in transformed-but-uncropped coordinates.
        image = applyPreCropGeometry(image, settings: s)
        image = SelectiveAdjustments.applySpots(selectivePaths.spots, to: image)
        image = SelectiveAdjustments.applyRedEyes(s.redEyes, to: image)
        image = SelectiveAdjustments.applyMasks(
            selectivePaths.masks,
            to: image,
            quality: quality
        )
        image = applyCrop(image, settings: s)

        // 14. Post-crop vignette, then settled-only grain.
        if s.vignette != 0 {
            image = applyVignette(to: image, settings: s)
        }
        if quality == .settled, s.grain > 0 {
            image = applyGrain(
                to: image, amount: s.grain, size: s.grainSize,
                roughness: s.grainRoughness
            )
        }
        return image
    }

    // MARK: Cubes / optics

    /// Applies Point Color only where all unpremultiplied RGB components are in
    /// its 0...1 LUT domain. `CIColorCubeWithColorSpace` clamps its lookup input,
    /// so extended-range pixels must come from the untouched source image.
    static func applyPointColorCube(
        _ cube: ColorCubeEngine.Cube,
        to image: CIImage
    ) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull,
              extent.width > 0, extent.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
              let nominalMask = nominalRGBMask(for: image, extent: extent)
        else { return image }

        let adjusted = applyCube(cube, to: image, colorSpace: colorSpace)
            .cropped(to: extent)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = adjusted
        blend.backgroundImage = image
        blend.maskImage = nominalMask
        return (blend.outputImage ?? image).cropped(to: extent)
    }

    private static func nominalRGBMask(for image: CIImage, extent: CGRect) -> CIImage? {
        let minimum = CIFilter.minimumComponent()
        minimum.inputImage = image
        let lowerBound = CIFilter.colorThreshold()
        lowerBound.inputImage = minimum.outputImage?.cropped(to: extent)
        lowerBound.threshold = 0

        let maximum = CIFilter.maximumComponent()
        maximum.inputImage = image
        let distanceBelowUpperBound = CIFilter.colorMatrix()
        distanceBelowUpperBound.inputImage = maximum.outputImage?.cropped(to: extent)
        distanceBelowUpperBound.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
        distanceBelowUpperBound.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
        distanceBelowUpperBound.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
        distanceBelowUpperBound.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        distanceBelowUpperBound.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
        let upperBound = CIFilter.colorThreshold()
        upperBound.inputImage = distanceBelowUpperBound.outputImage?.cropped(to: extent)
        upperBound.threshold = 0

        let intersection = CIFilter.minimumCompositing()
        intersection.inputImage = lowerBound.outputImage?.cropped(to: extent)
        intersection.backgroundImage = upperBound.outputImage?.cropped(to: extent)
        guard let combined = intersection.outputImage?.cropped(to: extent) else { return nil }

        // The blend mask must be independent of source alpha.
        let opaque = CIFilter.colorMatrix()
        opaque.inputImage = combined
        opaque.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        opaque.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        opaque.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        opaque.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        opaque.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return opaque.outputImage?.cropped(to: extent)
    }

    private static func applyCube(
        _ cube: ColorCubeEngine.Cube,
        to image: CIImage,
        colorSpace: CGColorSpace? = nil
    ) -> CIImage {
        if let colorSpace,
           let filter = CIFilter(name: "CIColorCubeWithColorSpace") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(cube.dimension, forKey: "inputCubeDimension")
            filter.setValue(cube.data, forKey: "inputCubeData")
            filter.setValue(colorSpace, forKey: "inputColorSpace")
            return filter.outputImage ?? image
        }

        let filter = CIFilter.colorCube()
        filter.inputImage = image
        filter.cubeDimension = Float(cube.dimension)
        filter.cubeData = cube.data
        return filter.outputImage ?? image
    }

    private static func applyOptics(
        to input: CIImage,
        settings s: DevelopSettings,
        quality: PreviewRenderQuality
    ) -> CIImage {
        let parameters = opticsParameters(for: s)
        let defringeActive = s.opticsDefringePurple > 0 || s.opticsDefringeGreen > 0
        guard parameters.distortionScale != 0 || parameters.vignetteIntensity != 0
            || parameters.redChannelScale != 1 || parameters.blueChannelScale != 1
            || defringeActive else { return input }
        let extent = input.extent
        guard !extent.isInfinite, !extent.isNull, extent.width > 0, extent.height > 0 else {
            return input
        }
        var image = input

        if parameters.distortionScale != 0 {
            let f = CIFilter.bumpDistortion()
            f.inputImage = image.clampedToExtent()
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(hypot(extent.width, extent.height) * 0.5)
            f.scale = Float(parameters.distortionScale)
            image = (f.outputImage ?? image).cropped(to: extent)
        }

        if parameters.redChannelScale != 1 || parameters.blueChannelScale != 1 {
            image = applyChromaticAberration(
                to: image,
                redScale: parameters.redChannelScale,
                blueScale: parameters.blueChannelScale,
                extent: extent
            )
        }

        if parameters.vignetteIntensity != 0 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(min(extent.width, extent.height)
                * (0.2 + 0.65 * unit(s.opticsVignettingMidpoint)))
            f.falloff = Float(0.35 + 0.65 * (1 - unit(s.opticsVignettingMidpoint)))
            f.intensity = Float(parameters.vignetteIntensity)
            image = (f.outputImage ?? image).cropped(to: extent)
        }

        if let cube = ColorCubeEngine.defringeCube(
            purpleAmount: s.opticsDefringePurple,
            purpleHueLo: s.opticsDefringePurpleHueLo,
            purpleHueHi: s.opticsDefringePurpleHueHi,
            greenAmount: s.opticsDefringeGreen,
            greenHueLo: s.opticsDefringeGreenHueLo,
            greenHueHi: s.opticsDefringeGreenHueHi
        ) {
            let recolored = applyCube(cube, to: image)
            let edges = CIFilter.edges()
            edges.inputImage = image
            edges.intensity = quality == .interactive ? 2.5 : 4.5
            let maximum = CIFilter.maximumComponent()
            maximum.inputImage = edges.outputImage?.cropped(to: extent)
            let shape = CIFilter.colorControls()
            shape.inputImage = maximum.outputImage
            shape.saturation = 0
            shape.contrast = 2.2
            shape.brightness = -0.08
            if let mask = shape.outputImage?.cropped(to: extent) {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = recolored
                blend.backgroundImage = image
                blend.maskImage = mask
                image = (blend.outputImage ?? image).cropped(to: extent)
            }
        }
        return image.cropped(to: extent)
    }

    private static func applyChromaticAberration(
        to image: CIImage,
        redScale: Double,
        blueScale: Double,
        extent: CGRect
    ) -> CIImage {
        func channel(_ index: Int, scale: Double) -> CIImage? {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = image
            let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
            matrix.rVector = index == 0 ? CIVector(x: 1, y: 0, z: 0, w: 0) : zero
            matrix.gVector = index == 1 ? CIVector(x: 0, y: 1, z: 0, w: 0) : zero
            matrix.bVector = index == 2 ? CIVector(x: 0, y: 0, z: 1, w: 0) : zero
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            guard var output = matrix.outputImage else { return nil }
            if scale != 1 {
                let transform = CGAffineTransform(
                    a: scale, b: 0, c: 0, d: scale,
                    tx: extent.midX * (1 - scale),
                    ty: extent.midY * (1 - scale)
                )
                output = output.clampedToExtent().transformed(by: transform)
            }
            return output.cropped(to: extent)
        }

        guard let red = channel(0, scale: redScale),
              let green = channel(1, scale: 1),
              let blue = channel(2, scale: blueScale)
        else { return image }

        let rg = CIFilter.additionCompositing()
        rg.inputImage = red
        rg.backgroundImage = green
        let rgb = CIFilter.additionCompositing()
        rgb.inputImage = blue
        rgb.backgroundImage = rg.outputImage
        guard let combined = rgb.outputImage else { return image }

        let alpha = CIFilter.colorMatrix()
        alpha.inputImage = combined
        alpha.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        alpha.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        alpha.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        alpha.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (alpha.outputImage ?? image).cropped(to: extent)
    }

    // MARK: Detail

    private static func applyNoiseReduction(
        to input: CIImage,
        settings s: DevelopSettings,
        includeBasics: Bool
    ) -> CIImage {
        let extent = input.extent
        let postScale = includeBasics ? 1.0 : 0.35
        var image = input

        if s.noiseReduction > 0 {
            let detail = unit(s.noiseReductionDetail)
            let contrast = unit(s.noiseReductionContrast)
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = Float(min(0.075,
                s.noiseReduction * postScale * (0.045 - detail * 0.012)))
            f.sharpness = Float(0.15 + detail * 0.5 + contrast * 0.2)
            image = (f.outputImage ?? image).cropped(to: extent)

            if contrast > 0 {
                let restore = CIFilter.unsharpMask()
                restore.inputImage = image
                restore.radius = Float(2 + contrast * 5)
                restore.intensity = Float(s.noiseReduction * postScale * contrast * 0.35)
                image = (restore.outputImage ?? image).cropped(to: extent)
            }
        }

        if s.colorNoiseReduction > 0 {
            let detail = unit(s.colorNoiseReductionDetail)
            let smoothness = unit(s.colorNoiseReductionSmoothness)
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(0.8 + smoothness * 5.2)
            if let blurred = blur.outputImage?.cropped(to: extent) {
                let color = CIFilter.colorBlendMode()
                color.inputImage = blurred
                color.backgroundImage = image
                if let smoothed = color.outputImage {
                    let mix = CIFilter.dissolveTransition()
                    mix.inputImage = image
                    mix.targetImage = smoothed
                    mix.time = Float(min(1,
                        s.colorNoiseReduction * postScale * (0.9 - detail * 0.55)))
                    image = (mix.outputImage ?? image).cropped(to: extent)
                }
            }
        }
        return image
    }

    private static func applySharpening(
        to input: CIImage,
        settings s: DevelopSettings,
        includeBasics: Bool,
        quality: PreviewRenderQuality
    ) -> CIImage {
        let extent = input.extent
        let amount = s.sharpness * (includeBasics ? 1 : 0.55)
        let detail = unit(s.sharpenDetail)
        let base = CIFilter.unsharpMask()
        base.inputImage = input
        base.radius = Float(0.65 + unit(s.sharpenRadius) * 3.35)
        base.intensity = Float(amount * (0.65 + detail * 0.35))
        var sharpened = (base.outputImage ?? input).cropped(to: extent)

        if quality == .settled, detail > 0 {
            let fine = CIFilter.unsharpMask()
            fine.inputImage = sharpened
            fine.radius = Float(0.35 + detail * 0.55)
            fine.intensity = Float(amount * detail * 0.45)
            sharpened = (fine.outputImage ?? sharpened).cropped(to: extent)
        }

        let masking = unit(s.sharpenMasking)
        guard quality == .settled, masking > 0 else { return sharpened }
        let edges = CIFilter.edges()
        edges.inputImage = input
        edges.intensity = Float(1.5 + masking * 7.5)
        let maximum = CIFilter.maximumComponent()
        maximum.inputImage = edges.outputImage?.cropped(to: extent)
        let shape = CIFilter.colorControls()
        shape.inputImage = maximum.outputImage
        shape.saturation = 0
        shape.contrast = Float(1.5 + masking * 3.5)
        shape.brightness = Float(-masking * 0.12)
        guard let mask = shape.outputImage?.cropped(to: extent) else { return sharpened }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = sharpened
        blend.backgroundImage = input
        blend.maskImage = mask
        return (blend.outputImage ?? sharpened).cropped(to: extent)
    }

    // MARK: Vignette / grain

    private static func applyVignette(to image: CIImage, settings s: DevelopSettings) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull else { return image }
        let geometry = vignetteGeometry(
            extent: extent,
            midpoint: s.vignetteMidpoint,
            roundness: s.vignetteRoundness,
            feather: s.vignetteFeather
        )

        let rectangle = CIFilter.roundedRectangleGenerator()
        rectangle.extent = geometry.innerRect
        rectangle.radius = Float(geometry.cornerRadius)
        rectangle.smoothness = 1
        rectangle.color = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: extent)
        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = rectangle.outputImage
        composite.backgroundImage = white
        guard var mask = composite.outputImage?.cropped(to: extent) else { return image }
        if geometry.blurRadius > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = mask.clampedToExtent()
            blur.radius = Float(geometry.blurRadius)
            mask = (blur.outputImage ?? mask).cropped(to: extent)
        }

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(s.vignette < 0 ? s.vignette * 1.45 : s.vignette * 0.85)
        var adjusted = exposure.outputImage ?? image

        if s.vignette < 0, s.vignetteHighlights > 0 {
            let highlightMask = luminanceMask(
                of: image, extent: extent, scale: unit(s.vignetteHighlights)
            )
            let protect = CIFilter.blendWithMask()
            protect.inputImage = image
            protect.backgroundImage = adjusted
            protect.maskImage = highlightMask
            adjusted = protect.outputImage ?? adjusted
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = adjusted
        blend.backgroundImage = image
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: extent)
    }

    private static func luminanceMask(of image: CIImage, extent: CGRect, scale: Double) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        let r = 0.2126 * scale, g = 0.7152 * scale, b = 0.0722 * scale
        let vector = CIVector(x: r, y: g, z: b, w: 0)
        f.rVector = vector
        f.gVector = vector
        f.bVector = vector
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return (f.outputImage ?? image).cropped(to: extent)
    }

    private static func applyGrain(
        to image: CIImage,
        amount: Double,
        size: Double,
        roughness: Double
    ) -> CIImage {
        let extent = image.extent.isInfinite
            ? CGRect(x: 0, y: 0, width: 2048, height: 2048)
            : image.extent
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let parameters = grainParameters(amount: amount, size: size, roughness: roughness)

        func monochrome(_ source: CIImage, scale: Double, offset: CGFloat) -> CIImage? {
            let transformed = source.transformed(by: CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale, tx: offset, ty: -offset
            ))
            let mono = CIFilter.colorMatrix()
            mono.inputImage = transformed
            mono.rVector = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
            mono.gVector = mono.rVector
            mono.bVector = mono.rVector
            mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            mono.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return mono.outputImage?.cropped(to: extent)
        }

        guard let coarse = monochrome(noise, scale: parameters.coarseScale, offset: 0),
              let fine = monochrome(noise, scale: parameters.fineScale, offset: 31)
        else { return image }
        let textureMix = CIFilter.dissolveTransition()
        textureMix.inputImage = coarse
        textureMix.targetImage = fine
        textureMix.time = Float(parameters.fineMix)
        guard let texture = textureMix.outputImage?.cropped(to: extent) else { return image }

        let contrast = CIFilter.colorControls()
        contrast.inputImage = texture
        contrast.saturation = 0
        contrast.contrast = Float(1 + unit(roughness) * 0.65)
        contrast.brightness = 0
        let overlay = CIFilter.overlayBlendMode()
        overlay.inputImage = contrast.outputImage ?? texture
        overlay.backgroundImage = image
        guard let blended = overlay.outputImage else { return image }

        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = blended
        mix.time = Float(parameters.opacity)
        return mix.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Geometry

    /// Maps a transformed-but-uncropped top-left point back to the exact image
    /// entering Point Color. Geometry is inverted in reverse render order so
    /// sampling never reads a colour created by spatial interpolation.
    static func pointColorSourceNormalizedPoint(
        fromTransformed point: NormalizedPoint,
        sourceSize: CGSize,
        settings s: DevelopSettings
    ) -> NormalizedPoint? {
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y),
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let sourceExtent = CGRect(origin: .zero, size: sourceSize)
        let flip = geometryFlipTransform(extent: sourceExtent, settings: s)
        let quarterTurn = geometryQuarterTurn(
            extent: sourceExtent,
            turns: s.rotationQuarterTurns
        )
        let transformedExtent = quarterTurn.extent
        let straighten = geometryStraightenTransform(
            extent: transformedExtent,
            degrees: s.straighten
        )
        let perspective = geometryPerspectiveTransform(
            extent: transformedExtent,
            vertical: s.geometryVertical,
            horizontal: s.geometryHorizontal
        )
        let frame = geometryFrameTransform(extent: transformedExtent, settings: s)

        var mapped = CGPoint(
            x: point.x * transformedExtent.width,
            y: (1 - point.y) * transformedExtent.height
        )
        if let frame {
            guard let inverse = inverse(frame) else { return nil }
            mapped = mapped.applying(inverse)
        }
        if let perspective {
            guard let unit = perspective.inverted()?.applying(mapped) else { return nil }
            mapped = CGPoint(
                x: unit.x * transformedExtent.width,
                y: unit.y * transformedExtent.height
            )
        }
        if let straighten {
            guard let inverse = inverse(straighten) else { return nil }
            mapped = mapped.applying(inverse)
        }
        if let inverse = inverse(quarterTurn.transform) {
            mapped = mapped.applying(inverse)
        } else {
            return nil
        }
        if let flip {
            guard let inverse = inverse(flip) else { return nil }
            mapped = mapped.applying(inverse)
        }

        let normalized = NormalizedPoint(
            x: Double(mapped.x / sourceExtent.width),
            y: Double(1 - mapped.y / sourceExtent.height)
        )
        let tolerance = 0.000_001
        guard normalized.x >= -tolerance, normalized.x <= 1 + tolerance,
              normalized.y >= -tolerance, normalized.y <= 1 + tolerance else { return nil }
        return NormalizedPoint(
            x: min(1, max(0, normalized.x)),
            y: min(1, max(0, normalized.y))
        )
    }

    /// Applies only the geometry needed to align a pre-Point-Color image with
    /// the visible preview. Spatial edits and post-crop effects are excluded.
    static func applyViewportGeometry(
        to input: CIImage,
        settings: DevelopSettings
    ) -> CIImage {
        applyCrop(applyPreCropGeometry(input, settings: settings), settings: settings)
    }

    private static func applyPreCropGeometry(
        _ input: CIImage,
        settings s: DevelopSettings
    ) -> CIImage {
        var image = input
        var e = image.extent
        guard !e.isInfinite, !e.isNull else { return image }

        // Flips.
        if let transform = geometryFlipTransform(extent: e, settings: s) {
            image = image.transformed(by: transform)
        }

        // 90° rotation.
        let quarterTurn = geometryQuarterTurn(extent: e, turns: s.rotationQuarterTurns)
        if !quarterTurn.transform.isIdentity {
            image = image.transformed(by: quarterTurn.transform)
            e = quarterTurn.extent
        }

        // Rotate around frame centre and zoom just enough to avoid empty corners.
        if let transform = geometryStraightenTransform(extent: e, degrees: s.straighten) {
            image = preserveFrame(image.transformed(by: transform), extent: e)
        }

        // Manual vertical/horizontal perspective. The warped result is cropped
        // back to the established frame so downstream extents stay finite.
        if s.geometryVertical != 0 || s.geometryHorizontal != 0 {
            let corners = geometryPerspectiveCorners(
                extent: e,
                vertical: s.geometryVertical,
                horizontal: s.geometryHorizontal
            )
            let f = CIFilter.perspectiveTransform()
            f.inputImage = image
            f.topLeft = corners.topLeft
            f.topRight = corners.topRight
            f.bottomRight = corners.bottomRight
            f.bottomLeft = corners.bottomLeft
            image = preserveFrame(f.outputImage ?? image, extent: e)
        }

        // Aspect, scale and offsets share one resampling pass around frame centre.
        if let transform = geometryFrameTransform(extent: e, settings: s) {
            image = preserveFrame(image.transformed(by: transform), extent: e)
        }

        return image
    }

    private static func geometryFlipTransform(
        extent: CGRect,
        settings s: DevelopSettings
    ) -> CGAffineTransform? {
        guard s.flipH || s.flipV else { return nil }
        return CGAffineTransform(
            a: s.flipH ? -1 : 1,
            b: 0,
            c: 0,
            d: s.flipV ? -1 : 1,
            tx: s.flipH ? extent.width : 0,
            ty: s.flipV ? extent.height : 0
        )
    }

    private static func geometryQuarterTurn(
        extent: CGRect,
        turns rawTurns: Int
    ) -> (transform: CGAffineTransform, extent: CGRect) {
        let turns = ((rawTurns % 4) + 4) % 4
        switch turns {
        case 1:
            return (
                CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: extent.width),
                CGRect(x: 0, y: 0, width: extent.height, height: extent.width)
            )
        case 2:
            return (
                CGAffineTransform(
                    a: -1, b: 0, c: 0, d: -1,
                    tx: extent.width, ty: extent.height
                ),
                CGRect(origin: .zero, size: extent.size)
            )
        case 3:
            return (
                CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: extent.height, ty: 0),
                CGRect(x: 0, y: 0, width: extent.height, height: extent.width)
            )
        default:
            return (.identity, CGRect(origin: .zero, size: extent.size))
        }
    }

    private static func geometryStraightenTransform(
        extent: CGRect,
        degrees: Double
    ) -> CGAffineTransform? {
        guard degrees.isFinite, degrees != 0, extent.width > 0, extent.height > 0 else {
            return nil
        }
        let angle = degrees * .pi / 180
        let cosine = cos(angle)
        let sine = sin(angle)
        let absoluteCosine = abs(cosine)
        let absoluteSine = abs(sine)
        let coverScale = max(
            absoluteCosine + absoluteSine * extent.height / extent.width,
            absoluteCosine + absoluteSine * extent.width / extent.height
        )
        let a = coverScale * cosine
        let b = coverScale * sine
        let c = -coverScale * sine
        let d = coverScale * cosine
        return CGAffineTransform(
            a: a,
            b: b,
            c: c,
            d: d,
            tx: extent.midX - a * extent.midX - c * extent.midY,
            ty: extent.midY - b * extent.midX - d * extent.midY
        )
    }

    private static func geometryPerspectiveTransform(
        extent: CGRect,
        vertical: Double,
        horizontal: Double
    ) -> ProjectiveTransform? {
        guard vertical != 0 || horizontal != 0 else { return nil }
        let corners = geometryPerspectiveCorners(
            extent: extent,
            vertical: vertical,
            horizontal: horizontal
        )
        return ProjectiveTransform.unitSquareToQuadrilateral(
            bottomLeft: corners.bottomLeft,
            bottomRight: corners.bottomRight,
            topRight: corners.topRight,
            topLeft: corners.topLeft
        )
    }

    private static func geometryFrameTransform(
        extent: CGRect,
        settings s: DevelopSettings
    ) -> CGAffineTransform? {
        guard s.geometryAspect != 0 || s.geometryScale != 1
            || s.geometryOffsetX != 0 || s.geometryOffsetY != 0 else { return nil }
        let aspect = pow(2, signedUnit(s.geometryAspect) * 0.5)
        let scale = bounded(s.geometryScale, 0.5...1.5, fallback: 1)
        let scaleX = scale / aspect
        let scaleY = scale * aspect
        let offsetX = signedUnit(s.geometryOffsetX) * extent.width * 0.5
        let offsetY = signedUnit(s.geometryOffsetY) * extent.height * 0.5
        return CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: extent.midX * (1 - scaleX) + offsetX,
            ty: extent.midY * (1 - scaleY) + offsetY
        )
    }

    private static func inverse(_ transform: CGAffineTransform) -> CGAffineTransform? {
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > .ulpOfOne else { return nil }
        return transform.inverted()
    }

    private static func applyCrop(_ input: CIImage, settings s: DevelopSettings) -> CIImage {
        guard !s.isFullFrame else { return input }
        let e = input.extent
        guard !e.isInfinite, !e.isNull else { return input }
        var image = input

        // Crop rectangle (normalised, origin top-left in UI → flip Y for CI).
        if !s.isFullFrame {
            let rect = CGRect(
                x: e.minX + s.cropX * e.width,
                y: e.minY + (1 - s.cropY - s.cropH) * e.height,
                width: s.cropW * e.width,
                height: s.cropH * e.height
            )
            image = reorigin(image.cropped(to: rect))
        }
        return image
    }

    /// Shifts an image so its extent origin is (0, 0).
    private static func reorigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, !e.isNull else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    private static func preserveFrame(_ image: CIImage, extent: CGRect) -> CIImage {
        let canvas = CIImage(color: .clear).cropped(to: extent)
        return image.composited(over: canvas).cropped(to: extent)
    }

    // MARK: Scaling / rasterising / encoding

    static func downscale(_ image: CIImage, maxPixelSize: Int) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull,
              extent.width > 0, extent.height > 0 else { return image }
        let longest = max(extent.width, extent.height)
        guard longest > CGFloat(maxPixelSize) else { return image }

        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = Float(CGFloat(maxPixelSize) / longest)
        f.aspectRatio = 1
        return f.outputImage ?? image
    }

    static func rasterize(
        _ image: CIImage,
        context: CIContext,
        colorSpace: CGColorSpace,
        format: CIFormat = .RGBA8
    ) throws -> RenderedImage {
        let extent = image.extent.isInfinite
            ? CGRect(x: 0, y: 0, width: 1024, height: 1024)
            : image.extent
        guard let cg = context.createCGImage(image, from: extent,
                                             format: format, colorSpace: colorSpace)
        else { throw RawPipelineError.renderFailed }
        return RenderedImage(cgImage: cg, pixelWidth: cg.width, pixelHeight: cg.height)
    }

    static func encode(_ cgImage: CGImage, options: ExportOptions,
                       colorSpace: CGColorSpace, to destination: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, utType(for: options.format), 1, nil
        ) else { throw RawPipelineError.encodeFailed }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: options.quality]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RawPipelineError.encodeFailed }
    }

    // MARK: Helpers

    private static func unit(_ value: Double) -> Double {
        bounded(value, 0...1, fallback: 0)
    }

    private static func signedUnit(_ value: Double) -> Double {
        bounded(value, -1...1, fallback: 0)
    }

    private static func bounded(
        _ value: Double,
        _ range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func clamp(_ value: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        min(max(value, lo), hi)
    }

    static func colorSpace(for space: ExportOptions.ColorSpace) -> CGColorSpace {
        switch space {
        case .sRGB:      return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB:  return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        }
    }

    static func utType(for format: ExportOptions.Format) -> CFString {
        switch format {
        case .jpeg: return "public.jpeg" as CFString
        case .heic: return "public.heic" as CFString
        case .tiff: return "public.tiff" as CFString
        case .png:  return "public.png" as CFString
        }
    }
}
