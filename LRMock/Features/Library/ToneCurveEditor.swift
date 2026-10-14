//
//  ToneCurveEditor.swift
//  RawLight
//
//  Interactive luminance tone curve. Five fixed-x control points whose y is
//  dragged to shape the curve; the smooth line is the same monotone-cubic LUT
//  the pipeline applies, so what you draw is exactly what you get.
//

import SwiftUI

struct ToneCurveEditor: View {
    @Binding var points: [CurvePoint]
    var onEditingChanged: (Bool, UUID) -> Bool = { _, _ in true }

    @State private var dragging: Int?
    @State private var editingOwner: UUID?
    @GestureState private var dragGestureActive = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.surface)
                grid(size: size)
                curvePath(size: size)
                    .stroke(Theme.textPrimary, lineWidth: 1.5)
                ForEach(points.indices, id: \.self) { i in
                    handle(index: i, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: dragGestureActive) { wasActive, isActive in
            if wasActive, !isActive { finishDrag() }
        }
        .onDisappear { finishDrag() }
    }

    // MARK: Pieces

    private func grid(size: CGSize) -> some View {
        Path { p in
            for k in 1..<4 {
                let x = size.width * CGFloat(k) / 4
                let y = size.height * CGFloat(k) / 4
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Theme.separator, lineWidth: 0.5)
    }

    private func curvePath(size: CGSize) -> Path {
        Path { p in
            let samples = 64
            for i in 0...samples {
                let x = Double(i) / Double(samples)
                let y = ToneCurveLUT.value(at: x, points: points)
                let pt = point(x: x, y: y, size: size)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func handle(index i: Int, size: CGSize) -> some View {
        let pt = point(x: points[i].x, y: points[i].y, size: size)
        return Circle()
            .fill(dragging == i ? Theme.accent : .white)
            .frame(width: 11, height: 11)
            .position(pt)
    }

    // MARK: Interaction

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragGestureActive) { _, isActive, _ in
                isActive = true
            }
            .onChanged { g in
                if dragging == nil {
                    guard beginEditingOwnership() else { return }
                    dragging = nearestIndex(to: g.location, size: size)
                }
                guard let i = dragging else { return }
                // x stays fixed; only y is adjustable (0 at bottom, 1 at top).
                let y = 1 - Double(g.location.y / size.height)
                points[i].y = min(1, max(0, y))
            }
            .onEnded { _ in finishDrag() }
    }

    private func finishDrag() {
        guard dragging != nil else { return }
        dragging = nil
        endEditingOwnership()
    }

    private func beginEditingOwnership() -> Bool {
        if editingOwner != nil { return true }
        let owner = UUID()
        guard onEditingChanged(true, owner) else { return false }
        editingOwner = owner
        return true
    }

    private func endEditingOwnership() {
        guard let owner = editingOwner else { return }
        editingOwner = nil
        _ = onEditingChanged(false, owner)
    }

    private func nearestIndex(to location: CGPoint, size: CGSize) -> Int {
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for i in points.indices {
            let px = points[i].x * Double(size.width)
            let d = abs(Double(location.x) - px)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    private func point(x: Double, y: Double, size: CGSize) -> CGPoint {
        CGPoint(x: x * Double(size.width), y: (1 - y) * Double(size.height))
    }
}
