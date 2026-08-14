//
//  Theme.swift
//  Pingly
//
//  Created by Senior iOS Developer on 14/08/26.
//

import SwiftUI

/// Centralized Production Design System & Theme Engine for Pingly matching the Sunset Pink-to-Violet App Icon
public enum AppTheme {
    
    // MARK: - Color Stop Tokens (Matching App Icon Gradient Palette)
    
    /// Warm Coral Pink-Red (#FF3B5C)
    public static let coralRed = Color(red: 1.00, green: 0.23, blue: 0.36)
    
    /// Vibrant Hot Magenta / Fuchsia (#D92B80)
    public static let hotMagenta = Color(red: 0.85, green: 0.17, blue: 0.50)
    
    /// Deep Violet Purple (#9B30D9)
    public static let deepViolet = Color(red: 0.61, green: 0.19, blue: 0.85)
    
    /// Electric Purple-Blue / Indigo (#6C3EE8)
    public static let electricIndigo = Color(red: 0.42, green: 0.24, blue: 0.91)
    
    // MARK: - Gradient Color Sets
    
    /// Complete 4-Stop Sunset Gradient Palette
    public static let gradientColors: [Color] = [
        coralRed,
        hotMagenta,
        deepViolet,
        electricIndigo
    ]
    
    /// Compact 2-Stop Accent Gradient Palette
    public static let compactGradientColors: [Color] = [
        coralRed,
        deepViolet
    ]
    
    // MARK: - Linear Gradients
    
    /// Primary Diagonal Sunset Gradient
    public static let primaryGradient = LinearGradient(
        gradient: Gradient(colors: gradientColors),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    /// Primary Horizontal Sunset Gradient
    public static let horizontalGradient = LinearGradient(
        gradient: Gradient(colors: gradientColors),
        startPoint: .leading,
        endPoint: .trailing
    )
    
    /// Radial Mesh Glow Gradient for Radar & PTT Active States
    public static let radialGlowGradient = RadialGradient(
        gradient: Gradient(colors: [hotMagenta.opacity(0.8), electricIndigo.opacity(0.4), Color.clear]),
        center: .center,
        startRadius: 10,
        endRadius: 160
    )
    
    // MARK: - App Tints & Accents
    
    /// Primary System Accent Tint
    public static let tintColor = Color(red: 0.82, green: 0.18, blue: 0.55) // #D12E8C
    
    /// Secondary Accent Tint
    public static let secondaryTint = Color(red: 0.55, green: 0.20, blue: 0.88)
    
    /// Soft Glass Tint for Overlays and Card Badges
    public static let glassTint = hotMagenta.opacity(0.12)
    
    /// Soft Ring Overlay Stroke Gradient
    public static let ringStrokeGradient = LinearGradient(
        gradient: Gradient(colors: [coralRed.opacity(0.6), deepViolet.opacity(0.6)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - View Extensions for Theme Application
extension View {
    /// Applies the signature sunset gradient as a background fill
    public func pinglyBrandGradientBackground() -> some View {
        self.background(AppTheme.primaryGradient)
    }
    
    /// Masks text or SF Symbol with the horizontal sunset gradient
    public func pinglyGradientText() -> some View {
        self.overlay(AppTheme.horizontalGradient)
            .mask(self)
    }
}
