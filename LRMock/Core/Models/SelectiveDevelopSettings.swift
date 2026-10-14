//
//  SelectiveDevelopSettings.swift
//  RawLight
//
//  Persisted value models for point-colour, masking, spot, and red-eye edits.
//

import Foundation

nonisolated enum SelectiveDevelopLimits {
    // Leaves headroom below the 2 MiB sidecar cap even with one-point strokes.
    static let maximumTotalPathPoints = 8_192
}

private nonisolated struct LossySelectiveValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

nonisolated enum SelectiveDevelopNormalization {
    static let malformedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    static let maximumNameScalarCount = 128
    static let maximumNameUTF8ByteCount = 512

    private static let lossyScanAttemptMultiplier = 4

    private static func requiresWholeArrayDecoding(_ decoder: Decoder) -> Bool {
        // SwiftData's composite decoder traps if asked for a nested unkeyed
        // container, so per-element lossy recovery remains JSON-only there.
        String(reflecting: Swift.type(of: decoder)) == "SwiftData.CompositeDecoder"
    }

    static func double<Key: CodingKey>(
        _ key: Key,
        from container: KeyedDecodingContainer<Key>,
        default defaultValue: Double
    ) -> Double {
        (try? container.decode(Double.self, forKey: key)) ?? defaultValue
    }

    static func bool<Key: CodingKey>(
        _ key: Key,
        from container: KeyedDecodingContainer<Key>,
        default defaultValue: Bool
    ) -> Bool {
        (try? container.decode(Bool.self, forKey: key)) ?? defaultValue
    }

    static func uuid<Key: CodingKey>(
        _ key: Key,
        from container: KeyedDecodingContainer<Key>
    ) -> UUID {
        (try? container.decode(UUID.self, forKey: key)) ?? malformedUUID
    }

    static func string<Key: CodingKey>(
        _ key: Key,
        from container: KeyedDecodingContainer<Key>,
        default defaultValue: String = ""
    ) -> String {
        (try? container.decode(String.self, forKey: key)) ?? defaultValue
    }

    static func clamp(
        _ value: Double,
        to range: ClosedRange<Double>,
        default defaultValue: Double = 0
    ) -> Double {
        guard value.isFinite else {
            return min(max(defaultValue, range.lowerBound), range.upperBound)
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func wrappedHue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: 1)
        let wrapped = remainder < 0 ? remainder + 1 : remainder
        return wrapped == 0 ? 0 : wrapped
    }

    static func canonicalAngle(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        var angle = value.truncatingRemainder(dividingBy: 360)
        if angle < -180 { angle += 360 }
        if angle >= 180 { angle -= 360 }
        return angle == 0 ? 0 : angle
    }

    static func truncatedName(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(maximumNameScalarCount)
        var byteCount = 0

        for scalar in value.unicodeScalars.prefix(maximumNameScalarCount) {
            let scalarByteCount = scalar.utf8.count
            guard byteCount + scalarByteCount <= maximumNameUTF8ByteCount else { break }
            result.append(scalar)
            byteCount += scalarByteCount
        }
        return String(result)
    }

    static func boundedLossyArray<Key: CodingKey, Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key,
        from container: KeyedDecodingContainer<Key>,
        decoder: Decoder,
        maximumCount: Int
    ) -> [Value] {
        guard maximumCount > 0 else { return [] }
        if requiresWholeArrayDecoding(decoder) {
            let decoded = (try? container.decode([Value].self, forKey: key)) ?? []
            return Array(decoded.prefix(maximumCount))
        }
        guard var values = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }

        var result: [Value] = []
        // Recover malformed siblings without walking an attacker-controlled
        // array indefinitely when few or no values can be decoded.
        let maximumAttempts = maximumCount * lossyScanAttemptMultiplier
        var attempts = 0
        while result.count < maximumCount, attempts < maximumAttempts, !values.isAtEnd {
            attempts += 1
            guard let decoded = try? values.decode(LossySelectiveValue<Value>.self) else {
                break
            }
            if let value = decoded.value {
                result.append(value)
            }
        }
        return result
    }

    static func boundedArray<Key: CodingKey, Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key,
        from container: KeyedDecodingContainer<Key>,
        decoder: Decoder,
        maximumCount: Int
    ) throws -> [Value] {
        if requiresWholeArrayDecoding(decoder) {
            let decoded = try container.decodeIfPresent([Value].self, forKey: key) ?? []
            return Array(decoded.prefix(maximumCount))
        }
        guard maximumCount > 0, container.contains(key) else { return [] }
        if try container.decodeNil(forKey: key) { return [] }

        var values = try container.nestedUnkeyedContainer(forKey: key)
        var result: [Value] = []
        for _ in 0..<maximumCount {
            guard !values.isAtEnd else { break }
            result.append(try values.decode(Value.self))
        }
        return result
    }
}

nonisolated struct NormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = SelectiveDevelopNormalization.clamp(x, to: 0...1)
        self.y = SelectiveDevelopNormalization.clamp(y, to: 0...1)
    }

    enum CodingKeys: String, CodingKey { case x, y }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: SelectiveDevelopNormalization.double(.x, from: container, default: 0),
            y: SelectiveDevelopNormalization.double(.y, from: container, default: 0)
        )
    }

    func normalized() -> NormalizedPoint {
        NormalizedPoint(x: x, y: y)
    }
}

nonisolated struct NormalizedVector: Codable, Equatable, Sendable {
    var dx: Double
    var dy: Double

    init(dx: Double, dy: Double) {
        self.dx = SelectiveDevelopNormalization.clamp(dx, to: -1...1)
        self.dy = SelectiveDevelopNormalization.clamp(dy, to: -1...1)
    }

    enum CodingKeys: String, CodingKey { case dx, dy }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dx: SelectiveDevelopNormalization.double(.dx, from: container, default: 0),
            dy: SelectiveDevelopNormalization.double(.dy, from: container, default: 0)
        )
    }

    func normalized() -> NormalizedVector {
        NormalizedVector(dx: dx, dy: dy)
    }
}

nonisolated struct PointColorAdjustment: Codable, Equatable, Sendable, Identifiable {
    static let maximumCount = 8

    var id: UUID
    var luminance: Double
    var chroma: Double
    var hue: Double
    var hueShift: Double
    var saturationShift: Double
    var luminanceShift: Double
    var variance: Double
    var range: Double
    var hueRange: Double
    var chromaRange: Double
    var luminanceRange: Double
    var location: NormalizedPoint?

    init(
        id: UUID = UUID(),
        luminance: Double = 0,
        chroma: Double = 0,
        hue: Double = 0,
        hueShift: Double = 0,
        saturationShift: Double = 0,
        luminanceShift: Double = 0,
        variance: Double = 0,
        range: Double = 0.5,
        hueRange: Double = 0.5,
        chromaRange: Double = 0.5,
        luminanceRange: Double = 0.5,
        location: NormalizedPoint? = nil
    ) {
        self.id = id
        self.luminance = SelectiveDevelopNormalization.clamp(luminance, to: 0...1)
        self.chroma = SelectiveDevelopNormalization.clamp(chroma, to: 0...0.5)
        self.hue = SelectiveDevelopNormalization.wrappedHue(hue)
        self.hueShift = SelectiveDevelopNormalization.clamp(hueShift, to: -1...1)
        self.saturationShift = SelectiveDevelopNormalization.clamp(saturationShift, to: -1...1)
        self.luminanceShift = SelectiveDevelopNormalization.clamp(luminanceShift, to: -1...1)
        self.variance = SelectiveDevelopNormalization.clamp(variance, to: -1...1)
        self.range = SelectiveDevelopNormalization.clamp(range, to: 0...1, default: 0.5)
        self.hueRange = SelectiveDevelopNormalization.clamp(hueRange, to: 0...1, default: 0.5)
        self.chromaRange = SelectiveDevelopNormalization.clamp(chromaRange, to: 0...1, default: 0.5)
        self.luminanceRange = SelectiveDevelopNormalization.clamp(luminanceRange, to: 0...1, default: 0.5)
        self.location = location?.normalized()
    }

    enum CodingKeys: String, CodingKey {
        case id, luminance, chroma, hue, hueShift, saturationShift, luminanceShift, variance
        case range, hueRange, chromaRange, luminanceRange, location
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: SelectiveDevelopNormalization.uuid(.id, from: container),
            luminance: SelectiveDevelopNormalization.double(.luminance, from: container, default: 0),
            chroma: SelectiveDevelopNormalization.double(.chroma, from: container, default: 0),
            hue: SelectiveDevelopNormalization.double(.hue, from: container, default: 0),
            hueShift: SelectiveDevelopNormalization.double(.hueShift, from: container, default: 0),
            saturationShift: SelectiveDevelopNormalization.double(.saturationShift, from: container, default: 0),
            luminanceShift: SelectiveDevelopNormalization.double(.luminanceShift, from: container, default: 0),
            variance: SelectiveDevelopNormalization.double(.variance, from: container, default: 0),
            range: SelectiveDevelopNormalization.double(.range, from: container, default: 0.5),
            hueRange: SelectiveDevelopNormalization.double(.hueRange, from: container, default: 0.5),
            chromaRange: SelectiveDevelopNormalization.double(.chromaRange, from: container, default: 0.5),
            luminanceRange: SelectiveDevelopNormalization.double(.luminanceRange, from: container, default: 0.5),
            location: try? container.decode(NormalizedPoint.self, forKey: .location)
        )
    }

    var isIdentity: Bool {
        hueShift == 0 && saturationShift == 0 && luminanceShift == 0 && variance == 0
    }

    func normalized() -> PointColorAdjustment {
        PointColorAdjustment(
            id: id,
            luminance: luminance,
            chroma: chroma,
            hue: hue,
            hueShift: hueShift,
            saturationShift: saturationShift,
            luminanceShift: luminanceShift,
            variance: variance,
            range: range,
            hueRange: hueRange,
            chromaRange: chromaRange,
            luminanceRange: luminanceRange,
            location: location
        )
    }
}

nonisolated struct LocalAdjustments: Codable, Equatable, Sendable {
    var temperature: Double
    var tint: Double
    var exposure: Double
    var contrast: Double
    var highlights: Double
    var shadows: Double
    var whites: Double
    var blacks: Double
    var texture: Double
    var clarity: Double
    var dehaze: Double
    var hue: Double
    var saturation: Double
    var sharpness: Double
    var noiseReduction: Double
    var amount: Double

    init(
        temperature: Double = 0,
        tint: Double = 0,
        exposure: Double = 0,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        texture: Double = 0,
        clarity: Double = 0,
        dehaze: Double = 0,
        hue: Double = 0,
        saturation: Double = 0,
        sharpness: Double = 0,
        noiseReduction: Double = 0,
        amount: Double = 1
    ) {
        self.temperature = SelectiveDevelopNormalization.clamp(temperature, to: -1...1)
        self.tint = SelectiveDevelopNormalization.clamp(tint, to: -1...1)
        self.exposure = SelectiveDevelopNormalization.clamp(exposure, to: -1...1)
        self.contrast = SelectiveDevelopNormalization.clamp(contrast, to: -1...1)
        self.highlights = SelectiveDevelopNormalization.clamp(highlights, to: -1...1)
        self.shadows = SelectiveDevelopNormalization.clamp(shadows, to: -1...1)
        self.whites = SelectiveDevelopNormalization.clamp(whites, to: -1...1)
        self.blacks = SelectiveDevelopNormalization.clamp(blacks, to: -1...1)
        self.texture = SelectiveDevelopNormalization.clamp(texture, to: -1...1)
        self.clarity = SelectiveDevelopNormalization.clamp(clarity, to: -1...1)
        self.dehaze = SelectiveDevelopNormalization.clamp(dehaze, to: -1...1)
        self.hue = SelectiveDevelopNormalization.clamp(hue, to: -1...1)
        self.saturation = SelectiveDevelopNormalization.clamp(saturation, to: -1...1)
        self.sharpness = SelectiveDevelopNormalization.clamp(sharpness, to: -1...1)
        self.noiseReduction = SelectiveDevelopNormalization.clamp(noiseReduction, to: -1...1)
        self.amount = SelectiveDevelopNormalization.clamp(amount, to: 0...2, default: 1)
    }

    enum CodingKeys: String, CodingKey {
        case temperature, tint, exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, hue, saturation, sharpness, noiseReduction, amount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            temperature: SelectiveDevelopNormalization.double(.temperature, from: container, default: 0),
            tint: SelectiveDevelopNormalization.double(.tint, from: container, default: 0),
            exposure: SelectiveDevelopNormalization.double(.exposure, from: container, default: 0),
            contrast: SelectiveDevelopNormalization.double(.contrast, from: container, default: 0),
            highlights: SelectiveDevelopNormalization.double(.highlights, from: container, default: 0),
            shadows: SelectiveDevelopNormalization.double(.shadows, from: container, default: 0),
            whites: SelectiveDevelopNormalization.double(.whites, from: container, default: 0),
            blacks: SelectiveDevelopNormalization.double(.blacks, from: container, default: 0),
            texture: SelectiveDevelopNormalization.double(.texture, from: container, default: 0),
            clarity: SelectiveDevelopNormalization.double(.clarity, from: container, default: 0),
            dehaze: SelectiveDevelopNormalization.double(.dehaze, from: container, default: 0),
            hue: SelectiveDevelopNormalization.double(.hue, from: container, default: 0),
            saturation: SelectiveDevelopNormalization.double(.saturation, from: container, default: 0),
            sharpness: SelectiveDevelopNormalization.double(.sharpness, from: container, default: 0),
            noiseReduction: SelectiveDevelopNormalization.double(.noiseReduction, from: container, default: 0),
            amount: SelectiveDevelopNormalization.double(.amount, from: container, default: 1)
        )
    }

    var isIdentity: Bool {
        temperature == 0 && tint == 0 && exposure == 0 && contrast == 0
            && highlights == 0 && shadows == 0 && whites == 0 && blacks == 0
            && texture == 0 && clarity == 0 && dehaze == 0 && hue == 0
            && saturation == 0 && sharpness == 0 && noiseReduction == 0 && amount == 1
    }

    func normalized() -> LocalAdjustments {
        LocalAdjustments(
            temperature: temperature,
            tint: tint,
            exposure: exposure,
            contrast: contrast,
            highlights: highlights,
            shadows: shadows,
            whites: whites,
            blacks: blacks,
            texture: texture,
            clarity: clarity,
            dehaze: dehaze,
            hue: hue,
            saturation: saturation,
            sharpness: sharpness,
            noiseReduction: noiseReduction,
            amount: amount
        )
    }
}

nonisolated enum MaskOperation: String, Codable, Equatable, Sendable {
    case add
    case subtract
    case intersect

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let operation = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown mask operation \(value)."
            )
        }
        self = operation
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct BrushStroke: Codable, Equatable, Sendable {
    static let maximumPointCount = 2_048

    var points: [NormalizedPoint]
    var size: Double
    var feather: Double
    var flow: Double
    var density: Double
    var erase: Bool

    init(
        points: [NormalizedPoint] = [],
        size: Double = 0.03,
        feather: Double = 0.5,
        flow: Double = 1,
        density: Double = 1,
        erase: Bool = false
    ) {
        self.points = points.prefix(Self.maximumPointCount).map { $0.normalized() }
        self.size = SelectiveDevelopNormalization.clamp(size, to: 0.001...0.25, default: 0.03)
        self.feather = SelectiveDevelopNormalization.clamp(feather, to: 0...1, default: 0.5)
        self.flow = SelectiveDevelopNormalization.clamp(flow, to: 0...1, default: 1)
        self.density = SelectiveDevelopNormalization.clamp(density, to: 0...1, default: 1)
        self.erase = erase
    }

    enum CodingKeys: String, CodingKey { case points, size, feather, flow, density, erase }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            points: SelectiveDevelopNormalization.boundedLossyArray(
                NormalizedPoint.self,
                forKey: .points,
                from: container,
                decoder: decoder,
                maximumCount: Self.maximumPointCount
            ),
            size: SelectiveDevelopNormalization.double(.size, from: container, default: 0.03),
            feather: SelectiveDevelopNormalization.double(.feather, from: container, default: 0.5),
            flow: SelectiveDevelopNormalization.double(.flow, from: container, default: 1),
            density: SelectiveDevelopNormalization.double(.density, from: container, default: 1),
            erase: SelectiveDevelopNormalization.bool(.erase, from: container, default: false)
        )
    }

    func normalized() -> BrushStroke {
        BrushStroke(points: points, size: size, feather: feather, flow: flow, density: density, erase: erase)
    }
}

nonisolated enum MaskShape: Codable, Equatable, Sendable {
    static let maximumStrokeCount = 128

    case brush(strokes: [BrushStroke])
    case linear(start: NormalizedPoint, end: NormalizedPoint)
    case radial(
        center: NormalizedPoint,
        radiusX: Double,
        radiusY: Double,
        angle: Double,
        feather: Double,
        inverted: Bool
    )

    private enum Kind: String {
        case brush
        case linear
        case radial
    }

    private enum CodingKeys: String, CodingKey {
        case kind, strokes, start, end, center, radiusX, radiusY, angle, feather, inverted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard
            let rawKind = try? container.decode(String.self, forKey: .kind),
            let kind = Kind(rawValue: rawKind)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown or missing mask shape kind."
            )
        }

        switch kind {
        case .brush:
            let strokes = SelectiveDevelopNormalization.boundedLossyArray(
                BrushStroke.self,
                forKey: .strokes,
                from: container,
                decoder: decoder,
                maximumCount: Self.maximumStrokeCount
            )
            self = .brush(strokes: strokes.map { $0.normalized() })
        case .linear:
            let start = (try? container.decode(NormalizedPoint.self, forKey: .start))
                ?? NormalizedPoint(x: 0, y: 0.5)
            let end = (try? container.decode(NormalizedPoint.self, forKey: .end))
                ?? NormalizedPoint(x: 1, y: 0.5)
            self = .linear(start: start.normalized(), end: end.normalized())
        case .radial:
            let center = (try? container.decode(NormalizedPoint.self, forKey: .center))
                ?? NormalizedPoint(x: 0.5, y: 0.5)
            self = .radial(
                center: center.normalized(),
                radiusX: SelectiveDevelopNormalization.clamp(
                    SelectiveDevelopNormalization.double(.radiusX, from: container, default: 0.25),
                    to: 0.0001...1,
                    default: 0.25
                ),
                radiusY: SelectiveDevelopNormalization.clamp(
                    SelectiveDevelopNormalization.double(.radiusY, from: container, default: 0.25),
                    to: 0.0001...1,
                    default: 0.25
                ),
                angle: SelectiveDevelopNormalization.canonicalAngle(
                    SelectiveDevelopNormalization.double(.angle, from: container, default: 0)
                ),
                feather: SelectiveDevelopNormalization.clamp(
                    SelectiveDevelopNormalization.double(.feather, from: container, default: 0.5),
                    to: 0...1,
                    default: 0.5
                ),
                inverted: SelectiveDevelopNormalization.bool(.inverted, from: container, default: false)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch normalized() {
        case let .brush(strokes):
            try container.encode(Kind.brush.rawValue, forKey: .kind)
            try container.encode(strokes, forKey: .strokes)
        case let .linear(start, end):
            try container.encode(Kind.linear.rawValue, forKey: .kind)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        case let .radial(center, radiusX, radiusY, angle, feather, inverted):
            try container.encode(Kind.radial.rawValue, forKey: .kind)
            try container.encode(center, forKey: .center)
            try container.encode(radiusX, forKey: .radiusX)
            try container.encode(radiusY, forKey: .radiusY)
            try container.encode(angle, forKey: .angle)
            try container.encode(feather, forKey: .feather)
            try container.encode(inverted, forKey: .inverted)
        }
    }

    func normalized() -> MaskShape {
        switch self {
        case let .brush(strokes):
            return .brush(strokes: strokes.prefix(Self.maximumStrokeCount).map { $0.normalized() })
        case let .linear(start, end):
            return .linear(start: start.normalized(), end: end.normalized())
        case let .radial(center, radiusX, radiusY, angle, feather, inverted):
            return .radial(
                center: center.normalized(),
                radiusX: SelectiveDevelopNormalization.clamp(radiusX, to: 0.0001...1, default: 0.25),
                radiusY: SelectiveDevelopNormalization.clamp(radiusY, to: 0.0001...1, default: 0.25),
                angle: SelectiveDevelopNormalization.canonicalAngle(angle),
                feather: SelectiveDevelopNormalization.clamp(feather, to: 0...1, default: 0.5),
                inverted: inverted
            )
        }
    }
}

nonisolated struct MaskComponent: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var operation: MaskOperation
    var inverted: Bool
    var shape: MaskShape

    init(
        id: UUID = UUID(),
        operation: MaskOperation = .add,
        inverted: Bool = false,
        shape: MaskShape = .brush(strokes: [])
    ) {
        self.id = id
        self.operation = operation
        self.inverted = inverted
        self.shape = shape.normalized()
    }

    enum CodingKeys: String, CodingKey { case id, operation, inverted, shape }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let shape = try container.decodeIfPresent(MaskShape.self, forKey: .shape) ?? .brush(strokes: [])
        let operation = container.contains(.operation)
            ? try container.decode(MaskOperation.self, forKey: .operation)
            : .add
        self.init(
            id: SelectiveDevelopNormalization.uuid(.id, from: container),
            operation: operation,
            inverted: SelectiveDevelopNormalization.bool(.inverted, from: container, default: false),
            shape: shape
        )
    }

    func normalized() -> MaskComponent {
        MaskComponent(id: id, operation: operation, inverted: inverted, shape: shape)
    }
}

nonisolated struct LocalMask: Codable, Equatable, Sendable, Identifiable {
    static let maximumCount = 32
    static let maximumComponentCount = 16

    var id: UUID
    var name: String
    var enabled: Bool
    var inverted: Bool
    var components: [MaskComponent]
    var adjustments: LocalAdjustments

    init(
        id: UUID = UUID(),
        name: String = "",
        enabled: Bool = true,
        inverted: Bool = false,
        components: [MaskComponent] = [],
        adjustments: LocalAdjustments = LocalAdjustments()
    ) {
        self.id = id
        self.name = SelectiveDevelopNormalization.truncatedName(name)
        self.enabled = enabled
        self.inverted = inverted
        self.components = components.prefix(Self.maximumComponentCount).map { $0.normalized() }
        self.adjustments = adjustments.normalized()
    }

    enum CodingKeys: String, CodingKey { case id, name, enabled, inverted, components, adjustments }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let components = try SelectiveDevelopNormalization.boundedArray(
            MaskComponent.self,
            forKey: .components,
            from: container,
            decoder: decoder,
            maximumCount: Self.maximumComponentCount
        )
        self.init(
            id: SelectiveDevelopNormalization.uuid(.id, from: container),
            name: SelectiveDevelopNormalization.string(.name, from: container),
            enabled: SelectiveDevelopNormalization.bool(.enabled, from: container, default: true),
            inverted: SelectiveDevelopNormalization.bool(.inverted, from: container, default: false),
            components: components,
            adjustments: (try? container.decode(LocalAdjustments.self, forKey: .adjustments))
                ?? LocalAdjustments()
        )
    }

    func normalized() -> LocalMask {
        LocalMask(
            id: id,
            name: name,
            enabled: enabled,
            inverted: inverted,
            components: components,
            adjustments: adjustments
        )
    }
}

nonisolated enum SpotMode: String, Codable, Equatable, Sendable {
    case remove
    case heal
    case clone

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let mode = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown spot mode \(value)."
            )
        }
        self = mode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct SpotCorrection: Codable, Equatable, Sendable, Identifiable {
    static let maximumCount = 256
    static let maximumPointCount = 2_048

    var id: UUID
    var mode: SpotMode
    var points: [NormalizedPoint]
    var size: Double
    var feather: Double
    var opacity: Double
    var sourceOffset: NormalizedVector?

    init(
        id: UUID = UUID(),
        mode: SpotMode = .remove,
        points: [NormalizedPoint] = [],
        size: Double = 0.02,
        feather: Double = 0.5,
        opacity: Double = 1,
        sourceOffset: NormalizedVector? = nil
    ) {
        self.id = id
        self.mode = mode
        self.points = points.prefix(Self.maximumPointCount).map { $0.normalized() }
        self.size = SelectiveDevelopNormalization.clamp(size, to: 0.001...0.25, default: 0.02)
        self.feather = SelectiveDevelopNormalization.clamp(feather, to: 0...1, default: 0.5)
        self.opacity = SelectiveDevelopNormalization.clamp(opacity, to: 0...1, default: 1)
        self.sourceOffset = sourceOffset?.normalized()
    }

    enum CodingKeys: String, CodingKey { case id, mode, points, size, feather, opacity, sourceOffset }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = container.contains(.mode)
            ? try container.decode(SpotMode.self, forKey: .mode)
            : .remove
        self.init(
            id: SelectiveDevelopNormalization.uuid(.id, from: container),
            mode: mode,
            points: SelectiveDevelopNormalization.boundedLossyArray(
                NormalizedPoint.self,
                forKey: .points,
                from: container,
                decoder: decoder,
                maximumCount: Self.maximumPointCount
            ),
            size: SelectiveDevelopNormalization.double(.size, from: container, default: 0.02),
            feather: SelectiveDevelopNormalization.double(.feather, from: container, default: 0.5),
            opacity: SelectiveDevelopNormalization.double(.opacity, from: container, default: 1),
            sourceOffset: try? container.decode(NormalizedVector.self, forKey: .sourceOffset)
        )
    }

    func normalized() -> SpotCorrection {
        SpotCorrection(
            id: id,
            mode: mode,
            points: points,
            size: size,
            feather: feather,
            opacity: opacity,
            sourceOffset: sourceOffset
        )
    }
}

nonisolated struct RedEyeCorrection: Codable, Equatable, Sendable, Identifiable {
    static let maximumCount = 64

    private struct RequiredCenter: Decodable {
        let x: Double
        let y: Double
    }

    var id: UUID
    var center: NormalizedPoint
    var radiusX: Double
    var radiusY: Double
    var pupilSize: Double
    var darken: Double
    var petEye: Bool
    var catchlight: NormalizedVector?

    init(
        id: UUID = UUID(),
        center: NormalizedPoint = NormalizedPoint(x: 0.5, y: 0.5),
        radiusX: Double = 0.02,
        radiusY: Double = 0.015,
        pupilSize: Double = 0.5,
        darken: Double = 0.5,
        petEye: Bool = false,
        catchlight: NormalizedVector? = nil
    ) {
        self.id = id
        self.center = center.normalized()
        self.radiusX = SelectiveDevelopNormalization.clamp(radiusX, to: 0.0001...0.5, default: 0.02)
        self.radiusY = SelectiveDevelopNormalization.clamp(radiusY, to: 0.0001...0.5, default: 0.015)
        self.pupilSize = SelectiveDevelopNormalization.clamp(pupilSize, to: 0...1, default: 0.5)
        self.darken = SelectiveDevelopNormalization.clamp(darken, to: 0...1, default: 0.5)
        self.petEye = petEye
        self.catchlight = petEye ? catchlight?.normalized() : nil
    }

    enum CodingKeys: String, CodingKey {
        case id, center, radiusX, radiusY, pupilSize, darken, petEye, catchlight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let petEye = SelectiveDevelopNormalization.bool(.petEye, from: container, default: false)
        let center: NormalizedPoint
        if container.contains(.center) {
            let decoded = try container.decode(RequiredCenter.self, forKey: .center)
            center = NormalizedPoint(x: decoded.x, y: decoded.y)
        } else {
            center = NormalizedPoint(x: 0.5, y: 0.5)
        }
        self.init(
            id: SelectiveDevelopNormalization.uuid(.id, from: container),
            center: center,
            radiusX: SelectiveDevelopNormalization.double(.radiusX, from: container, default: 0.02),
            radiusY: SelectiveDevelopNormalization.double(.radiusY, from: container, default: 0.015),
            pupilSize: SelectiveDevelopNormalization.double(.pupilSize, from: container, default: 0.5),
            darken: SelectiveDevelopNormalization.double(.darken, from: container, default: 0.5),
            petEye: petEye,
            catchlight: try? container.decode(NormalizedVector.self, forKey: .catchlight)
        )
    }

    func normalized() -> RedEyeCorrection {
        RedEyeCorrection(
            id: id,
            center: center,
            radiusX: radiusX,
            radiusY: radiusY,
            pupilSize: pupilSize,
            darken: darken,
            petEye: petEye,
            catchlight: catchlight
        )
    }
}
