//
//  ContentView.swift
//  Pingly
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
                // While checking credential state, display AnimatedSplashScreenView
                AnimatedSplashScreenView(isFinished: $isSplashFinished)
                    .transition(.opacity)
                
            case .authenticated:
                if !isSplashFinished {
                    AnimatedSplashScreenView(isFinished: $isSplashFinished)
                        .transition(.opacity)
                } else {
                    MainTabView()
                        .transition(.opacity)
                }
                
            case .unauthenticated:
                if !isSplashFinished {
                    AnimatedSplashScreenView(isFinished: $isSplashFinished)
                        .transition(.opacity)
                } else {
                    AppleSignInScreen()
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: signInManager.authState)
        .animation(.easeInOut(duration: 0.35), value: isSplashFinished)
    }
}

#Preview {
    ContentView()
}
