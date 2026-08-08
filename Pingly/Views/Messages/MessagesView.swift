//
//  MessagesView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Emergency Signal Drop & Mesh Timeline Screen
struct MessagesView: View {
    @StateObject var viewModel: MessagesViewModel
    @State private var showSOSDialog = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Constants.UI.Colors.backgroundDark
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // SOS Banner Trigger
                    sosHeaderBanner
                        .padding(.horizontal)
                        .padding(.top, 8)
                    
                    // Message Stream
                    messageList
                    
                    // Message Composer
                    messageComposer
                }
            }
            .navigationTitle("Signal Drop Mesh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Constants.UI.Colors.backgroundDark, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showSOSDialog) {
                sosSheetView
            }
        }
    }
    
    // MARK: - Emergency SOS Banner
    private var sosHeaderBanner: some View {
        Button(action: {
            showSOSDialog = true
        }) {
            HStack {
                ZStack {
                    Circle()
                        .fill(Constants.UI.Colors.sosDanger.opacity(0.25))
                        .frame(width: 44, height: 44)
                    Image(systemName: "sos.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Constants.UI.Colors.sosDanger)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("EMERGENCY DISTRESS BEACON")
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(Constants.UI.Colors.sosDanger)
                    Text("Tap to broadcast high-priority SOS mesh ping")
                        .font(.system(size: 12))
                        .foregroundColor(Constants.UI.Colors.textSecondary)
                }
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Constants.UI.Colors.textMuted)
            }
            .glassCardStyle(backgroundColor: Constants.UI.Colors.sosDanger.opacity(0.12))
        }
    }
    
    // MARK: - Message Stream List
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.count) { _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private func messageBubble(_ message: Message) -> some View {
        HStack {
            if message.isSOS {
                sosMessageCard(message)
            } else {
                normalMessageCard(message)
            }
        }
    }
    
    private func sosMessageCard(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("DISTRESS ALERT", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Constants.UI.Colors.sosDanger)
                Spacer()
                Text(message.timestamp.logTimeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Constants.UI.Colors.textMuted)
            }
            
            Text(message.text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Constants.UI.Colors.textPrimary)
            
            if let locStr = message.formattedLocation {
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                    Text("GPS: \(locStr)")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Constants.UI.Colors.warningOrange)
            }
            
            HStack {
                Text("Sender: \(message.senderName)")
                Spacer()
                Text("Hops: \(message.hopsCount)")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Constants.UI.Colors.textMuted)
        }
        .glassCardStyle(backgroundColor: Constants.UI.Colors.sosDanger.opacity(0.2))
    }
    
    private func normalMessageCard(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.senderName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Constants.UI.Colors.primaryAccent)
                Spacer()
                Text(message.timestamp.logTimeString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Constants.UI.Colors.textMuted)
            }
            
            Text(message.text)
                .font(.system(size: 14))
                .foregroundColor(Constants.UI.Colors.textPrimary)
            
            if let locStr = message.formattedLocation {
                Text("📍 Location: \(locStr)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Constants.UI.Colors.textSecondary)
            }
        }
        .glassCardStyle()
    }
    
    // MARK: - Composer
    private var messageComposer: some View {
        HStack(spacing: 8) {
            TextField("Drop emergency message...", text: $viewModel.messageText)
                .padding(12)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .foregroundColor(Constants.UI.Colors.textPrimary)
            
            Button(action: {
                viewModel.sendMessageDrop()
            }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Constants.UI.Colors.primaryAccent)
                    .clipShape(Circle())
            }
        }
        .padding()
        .background(Constants.UI.Colors.cardBackground)
    }
    
    // MARK: - SOS Trigger Dialog Sheet
    private var sosSheetView: some View {
        ZStack {
            Constants.UI.Colors.backgroundDark
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 60))
                    .foregroundColor(Constants.UI.Colors.sosDanger)
                
                Text("TRIGGER SOS DISTRESS BEACON")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundColor(Constants.UI.Colors.sosDanger)
                
                Text("Select your emergency situation to broadcast an immediate high-priority distress ping across all nearby Pingly mesh nodes:")
                    .font(.system(size: 14))
                    .foregroundColor(Constants.UI.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                VStack(spacing: 12) {
                    ForEach(EmergencyStatus.allCases.filter({ $0 != .normal })) { status in
                        Button(action: {
                            viewModel.triggerEmergencySOS(status: status)
                            showSOSDialog = false
                        }) {
                            HStack {
                                Image(systemName: status.iconName)
                                    .font(.system(size: 20))
                                Text(status.rawValue)
                                    .font(.system(size: 15, weight: .bold))
                                Spacer()
                                Image(systemName: "antenna.radiowaves.left.and.right")
                            }
                            .padding()
                            .foregroundColor(.white)
                            .background(status.themeColor.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .padding(.horizontal)
                
                Button("Cancel") {
                    showSOSDialog = false
                }
                .foregroundColor(Constants.UI.Colors.textMuted)
                .padding(.top, 10)
            }
            .padding()
        }
    }
}
