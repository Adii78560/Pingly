//
//  AppleSignInView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI
import AuthenticationServices

/// Minimalist SwiftUI Apple Sign-In Button Component
struct AppleSignInView: View {
    @ObservedObject var signInManager = AppleSignInManager.shared
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        SignInWithAppleButton(
            .signIn,
            onRequest: { request in
                request.requestedScopes = [.fullName, .email]
            },
            onCompletion: { result in
                switch result {
                case .success(let authorization):
                    if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
                        signInManager.handleCredential(appleIDCredential)
                    }
                case .failure:
                    break
                }
            }
        )
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 48)
        .cornerRadius(10)
    }
}

#Preview {
    AppleSignInView()
}
