//
//  Theme.swift
//  RawLight
//
//  Central dark palette for the Lightroom-style UI. One place to retune colours.
//

import SwiftUI

enum Theme {
    /// Darkest background (the grid / image canvas).
    static let canvas = Color(red: 0.07, green: 0.07, blue: 0.08)
    /// Panel background (sidebar + inspector).
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.12)
    /// Slightly raised surface (cards, fields).
    static let surface = Color(red: 0.16, green: 0.16, blue: 0.17)
    /// Hairline separators.
    static let separator = Color.white.opacity(0.08)

    static let accent = Color(red: 0.0, green: 0.60, blue: 1.0)

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
}
