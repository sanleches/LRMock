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

    @State private var editing = false
    @State private var editText = ""
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
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { withAnimation { value = defaultValue } }
                .onTapGesture { beginEdit() }
        }
    }

    private func beginEdit() {
        editText = String(format: "%.0f", displayValue)
        editing = true
        fieldFocused = true
    }

    private func commitEdit() {
        let cleaned = editText.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)
        if let typed = Double(cleaned) {
            let unscaled = typed / displayScale
            value = min(max(unscaled, range.lowerBound), range.upperBound)
        }
        editing = false
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
                    .onChanged { g in
                        let f = min(1, max(0, g.location.x / w))
                        value = range.lowerBound + f * span
                    }
            )
            .onTapGesture(count: 2) { value = defaultValue }
        }
        .frame(height: 18)
    }
}
