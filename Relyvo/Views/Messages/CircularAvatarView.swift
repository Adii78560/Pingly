//
//  CircularAvatarView.swift
//  Relyvo
//

import SwiftUI

struct CircularAvatarView: View {
    let senderAlias: String
    let senderID: String
    var size: CGFloat = 32
    var isOnline: Bool = true
    
    private var initials: String {
        let trimmed = senderAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let components = trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
        
        if components.count >= 2 {
            let first = components.first!.prefix(1).uppercased()
            let last = components.last!.prefix(1).uppercased()
            return first + last
        } else if let firstComponent = components.first {
            return String(firstComponent.prefix(2)).uppercased()
        }
        return ""
    }
    
    private var deterministicColor: Color {
        let hash = senderAlias.hashValue
        return Color(hue: Double(abs(hash) % 360) / 360.0, saturation: 0.65, brightness: 0.60)
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(deterministicColor)
            
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundColor(.white)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.375, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(Color.white.opacity(0.20), lineWidth: 1)
        )
        .contextMenu {
            VStack {
                Text(senderAlias)
                    .font(.headline)
                Text("ID: \(String(senderID.prefix(6)))")
                    .font(.caption)
                Text(isOnline ? "Status: Online" : "Status: Offline")
                    .font(.caption)
            }
        }
    }
}
