//
//  ScrubSlider.swift
//  RawLight
//
//  A compact, dense adjustment control used throughout the develop inspector.
//  Thin track, bipolar fill from the origin, draggable knob, and a numeric
//  readout that you can:
//    • single-tap to type an exact value, or
//    • double-tap to reset to the control's default.
//

import SwiftUI

struct ScrubSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var defaultValue: Double = 0
    /// Multiplier applied to the stored value for display (e.g. 100 → ±100).
    var displayScale: Double = 100
    var accent: Color = Theme.accent
    var onEditingChanged: (Bool, UUID) -> Bool = { _, _ in true }

    @State private var editing = false
    @State private var editText = ""
    @State private var dragging = false
    @State private var editingOwner: UUID?
    @GestureState private var dragGestureActive = false
    @FocusState private var fieldFocused: Bool

    private var isModified: Bool { abs(value - defaultValue) > 0.0005 }
    private var displayValue: Double { value * displayScale }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                valueControl
            }
            track
        }
        .contentShape(Rectangle())
        .onChange(of: dragGestureActive) { wasActive, isActive in
            if wasActive, !isActive { finishDrag() }
        }
        .onDisappear { cancelEditing() }
    }

    // MARK: Numeric value (tap to edit, double-tap to reset)

    @ViewBuilder
    private var valueControl: some View {
        if editing {
            TextField("", text: $editText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 46)
                .frame(minHeight: valueControlHeight)
                .focused($fieldFocused)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
                .onSubmit(commitEdit)
                .onChange(of: fieldFocused) { _, focused in if !focused { commitEdit() } }
        } else {
            Text(String(format: "%+.0f", displayValue))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(isModified ? Theme.textPrimary : Theme.textTertiary)
                .frame(minWidth: 34, alignment: .trailing)
                .frame(minWidth: valueControlWidth, minHeight: valueControlHeight)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2)
                        .onEnded { resetValue() }
                        .exclusively(before: TapGesture().onEnded { beginEdit() })
                )
        }
    }

    private func beginEdit() {
        guard !editing, beginEditingOwnership() else { return }
        editText = String(format: "%.0f", displayValue)
        editing = true
        fieldFocused = true
    }

    private func commitEdit() {
        guard editing else { return }
        let cleaned = editText.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)
        if let typed = Double(cleaned) {
            let unscaled = typed / displayScale
            value = min(max(unscaled, range.lowerBound), range.upperBound)
        }
        editing = false
        fieldFocused = false
        endEditingOwnership()
    }

    private func resetValue() {
        guard beginEditingOwnership() else { return }
        withAnimation { value = defaultValue }
        endEditingOwnership()
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            let frac = (value - range.lowerBound) / span
            let centerFrac = (defaultValue - range.lowerBound) / span
            let knobX = frac * w
            let centerX = centerFrac * w

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface).frame(height: 3)
                Rectangle()
                    .fill(accent)
                    .frame(width: max(0, abs(knobX - centerX)), height: 3)
                    .offset(x: min(knobX, centerX))
                Circle()
                    .fill(.white)
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: knobX - 6.5)
            }
            .frame(height: 16)
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragGestureActive) { _, isActive, _ in
                        isActive = true
                    }
                    .onChanged { g in
                        if !dragging {
                            guard beginEditingOwnership() else { return }
                            dragging = true
                        }
                        guard w > 0 else { return }
                        let f = min(1, max(0, g.location.x / w))
                        value = range.lowerBound + f * span
                    }
                    .onEnded { _ in finishDrag() }
            )
        }
        .frame(height: trackHeight)
    }

    private func finishDrag() {
        guard dragging else { return }
        dragging = false
        endEditingOwnership()
    }

    private func cancelEditing() {
        editing = false
        dragging = false
        fieldFocused = false
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

    private var valueControlWidth: CGFloat? {
        #if os(iOS)
        44
        #else
        nil
        #endif
    }

    private var valueControlHeight: CGFloat? {
        #if os(iOS)
        44
        #else
        nil
        #endif
    }

    private var trackHeight: CGFloat {
        #if os(iOS)
        44
        #else
        18
        #endif
    }
}
