//
//  ContentView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI

/// Root Application Navigation View managing Splash Screen & Authentication State transitions
struct ContentView: View {
    @ObservedObject var signInManager = AppleSignInManager.shared
    @State private var isSplashFinished = false
    
    var body: some View {
        ZStack {
            switch signInManager.authState {
            case .checking:
                AnimatedSplashScreenView(isFinished: $isSplashFinished)
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .scale(scale: 1.08).combined(with: .opacity)
                    ))
                    .zIndex(1)
                
            case .authenticated:
                if !isSplashFinished {
                    AnimatedSplashScreenView(isFinished: $isSplashFinished)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .scale(scale: 1.08).combined(with: .opacity)
                        ))
                        .zIndex(1)
                } else {
                    MainTabView()
                        .transition(.opacity)
                }
                
            case .unauthenticated:
                if !isSplashFinished {
                    AnimatedSplashScreenView(isFinished: $isSplashFinished)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .scale(scale: 1.08).combined(with: .opacity)
                        ))
                        .zIndex(1)
                } else {
                    AppleSignInScreen()
                        .transition(.opacity)
                }
            }
            
            InAppConsoleOverlay()
        }
        .animation(.easeInOut(duration: 0.35), value: signInManager.authState)
        .animation(.easeInOut(duration: 0.35), value: isSplashFinished)
    }
}

#Preview {
    ContentView()
}
