//
//  LoupeStage.swift
//  RawLight
//
//  The image stage inside the loupe: the live develop preview with
//    • pinch / trackpad-magnify zoom + pan, double-tap to toggle 1× ↔ 2×
//    • press-and-hold to peek the original ("before")
//    • a persistent Before/After toggle (driven from the toolbar)
//

import SwiftUI

struct LoupeStage: View {
    let asset: ImageAsset
    /// Persistent Before/After toggle from the toolbar.
    @Binding var comparing: Bool
    var onRender: (CGImage) -> Void

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    // Press-and-hold to peek the original, with a small delay so quick taps
    // don't flash.
    @State private var peeking = false
    @State private var peekTask: Task<Void, Never>?

    private var showingOriginal: Bool { comparing || peeking }

    private var currentZoom: CGFloat { max(1, min(8, zoom * pinch)) }

    var body: some View {
        GeometryReader { geo in
            DevelopPreview(
                asset: asset,
                settings: showingOriginal ? asset.develop.beforeSettings : asset.develop,
                onRender: showingOriginal ? { _ in } : onRender
            )
            .scaleEffect(currentZoom)
            .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnify)
            .simultaneousGesture(currentZoom > 1 ? pan : nil)
            .onTapGesture(count: 2) { toggleZoom() }
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 40,
                                pressing: handlePressing, perform: {})
            .overlay(alignment: .top) { if showingOriginal { beforeBadge } }
            .animation(.easeOut(duration: 0.12), value: showingOriginal)
        }
    }

    // MARK: Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                zoom = min(8, max(1, zoom * value.magnification))
                if zoom == 1 { offset = .zero }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .updating($dragOffset) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if zoom > 1 { zoom = 1; offset = .zero } else { zoom = 2 }
        }
    }

    private func handlePressing(_ isPressing: Bool) {
        peekTask?.cancel()
        if isPressing {
            peekTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { peeking = true }
            }
        } else {
            peeking = false
        }
    }

    // MARK: Overlay

    private var beforeBadge: some View {
        Text("BEFORE")
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 12)
    }
}
