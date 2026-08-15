//
//  AppleSignInScreen.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI
import AuthenticationServices

/// Minimalist Native Onboarding & Apple Sign-In Screen for Relayn
struct AppleSignInScreen: View {
    @ObservedObject var signInManager = AppleSignInManager.shared
    @Environment(\.colorScheme) var colorScheme
    
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    
    var body: some View {
        ZStack {
            // Sleek Apple Dark Background
            Color(red: 0.06, green: 0.07, blue: 0.10)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                // Minimalist Emblem & Title
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(AppTheme.glassTint)
                            .frame(width: 96, height: 96)
                        
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(AppTheme.primaryGradient)
                            .frame(width: 80, height: 80)
                            .shadow(color: AppTheme.hotMagenta.opacity(0.4), radius: 20, x: 0, y: 10)
                            .overlay(
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundColor(.white)
                            )
                    }
                    
                    VStack(spacing: 6) {
                        Text("Relayn")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("Off-Grid Communication")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                
                Spacer()
                Spacer()
                
                // Minimalist Sign-In Action (Single Face ID Scan)
                VStack(spacing: 16) {
                    SignInWithAppleButton(
                        .signIn,
                        onRequest: { request in
                            HapticsManager.shared.mediumImpact()
                            request.requestedScopes = [.fullName, .email]
                        },
                        onCompletion: { result in
                            switch result {
                            case .success(let authorization):
                                HapticsManager.shared.successFeedback()
                                if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                                    signInManager.handleCredential(appleIDCredential)
                                }
                            case .failure(let error):
                                let nsError = error as NSError
                                if nsError.code != ASAuthorizationError.canceled.rawValue {
                                    HapticsManager.shared.errorFeedback()
                                    errorMessage = error.localizedDescription
                                    showErrorAlert = true
                                }
                            }
                        }
                    )
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .white)
                    .frame(height: 52)
                    .cornerRadius(12)
                }

                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
        }
        .alert("Sign In Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An error occurred during authentication. Please try again.")
        }
    }
}

#Preview {
    AppleSignInScreen()
}
