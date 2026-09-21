//
//  ChatView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 13/08/26.
//

import SwiftUI

/// Detailed iMessage View conforming strictly to Apple HIG with location sharing
struct ChatView: View {
    @ObservedObject var viewModel: MessagesViewModel
    let conversation: Conversation
    
    @State private var inputText: String = ""
    @State private var showLocationOptionsSheet: Bool = false
    @State private var showRelativeLocationSheet: Bool = false
    @ObservedObject private var locationShareManager = LocationShareManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var currentConversation: Conversation {
        viewModel.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }
    
    private var conversationMessages: [Message] {
        currentConversation.messages
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Chat Messages List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(conversationMessages.enumerated()), id: \.element.id) { index, message in
                            let isMe = (message.senderID == NodeIdentity.shared.nodeID || message.originID == NodeIdentity.shared.nodeID)
                            let isLastInGroup: Bool = {
                                guard index < conversationMessages.count - 1 else { return true }
                                let nextMsg = conversationMessages[index + 1]
                                let sameSender = nextMsg.senderID == message.senderID
                                let timeDiff = abs(nextMsg.timestamp.timeIntervalSince(message.timestamp))
                                return !(sameSender && timeDiff < 60)
                            }()
                            let showAvatar = !isMe && isLastInGroup
                            
                            iMessageBubbleRow(message: message, isSentByMe: isMe, isLastInGroup: isLastInGroup, showAvatar: showAvatar)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: conversationMessages.count) { _ in
                    if let lastMsg = conversationMessages.last {
                        withAnimation {
                            proxy.scrollTo(lastMsg.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // 🔒 Communication Authorization Gate
            if DirectChatGate.shared.canSendDirectMessage(to: currentConversation.recipientNodeID) {
                // Native iMessage Input Dock
                iMessageInputDock
            } else {
                unauthorizedBanner
            }
        }
        .onAppear {
            viewModel.markConversationAsRead(conversationID: currentConversation.id)
            viewModel.selectedConversation = currentConversation
        }
        .onDisappear {
            if viewModel.selectedConversation?.id == currentConversation.id {
                viewModel.selectedConversation = nil
            }
        }
        .navigationTitle(currentConversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button(action: {
                    showLocationOptionsSheet = true
                }) {
                    VStack(spacing: 0) {
                        Text(currentConversation.displayName)
                            .font(.headline)
                            .foregroundColor(.primary)
                        HStack(spacing: 4) {
                            Text("iMessage • P2P Direct")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showRelativeLocationSheet = true
                }) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.primaryGradient)
                }
            }
        }
        .confirmationDialog("Location Sharing Options", isPresented: $showLocationOptionsSheet, titleVisibility: .visible) {
            Button("Ask for Location") {
                LocationShareManager.shared.requestLocation(from: currentConversation.id, displayName: currentConversation.displayName)
            }
            Button("Share My Location") {
                LocationShareManager.shared.startSharingLocation(with: currentConversation.id, displayName: currentConversation.displayName)
            }
            Button("Share Relative Position") {
                LocationShareManager.shared.shareRelativePosition(with: currentConversation.id, displayName: currentConversation.displayName)
            }
            Button("Show Relative Location") {
                showRelativeLocationSheet = true
            }
            if locationShareManager.activeSessions[currentConversation.id]?.isSharingLocal == true {
                Button("Stop Sharing Location", role: .destructive) {
                    LocationShareManager.shared.stopSharingLocation(with: currentConversation.id, displayName: currentConversation.displayName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showRelativeLocationSheet) {
            RelativeLocationView(
                remotePeerID: currentConversation.id,
                remoteDisplayName: currentConversation.displayName
            )
        }
    }
    
    // MARK: - iMessage Bubble Row
    private func iMessageBubbleRow(message: Message, isSentByMe: Bool, isLastInGroup: Bool, showAvatar: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isSystemLocationEvent(message.type) {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: systemLocationEventIcon(message.type))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.tintColor)
                    Text(message.text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
                Spacer()
            } else {
                if !isSentByMe {
                    if showAvatar {
                        CircularAvatarView(senderAlias: message.senderName, senderID: message.senderID, size: 32)
                    } else {
                        Spacer().frame(width: 32)
                    }
                } else {
                    Spacer(minLength: 40)
                }
                
                if message.type == .location, let lat = message.latitude, let lon = message.longitude {
                    LocationMessageCardView(
                        senderName: message.senderName,
                        latitude: lat,
                        longitude: lon,
                        accuracy: message.accuracy,
                        timestamp: message.timestamp,
                        isCurrentUser: isSentByMe,
                        isSOS: message.isSOS
                    )
                } else {
                    VStack(alignment: isSentByMe ? .trailing : .leading, spacing: 2) {
                        Text(message.text)
                            .font(.system(size: 16))
                            .foregroundColor(isSentByMe ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                isSentByMe ?
                                AnyShapeStyle(AppTheme.primaryGradient) :
                                AnyShapeStyle(Color(UIColor.secondarySystemBackground))
                            )
                            .clipShape(UnevenRoundedRectangle(
                                topLeadingRadius: 16,
                                bottomLeadingRadius: (isSentByMe || !isLastInGroup) ? 16 : 4,
                                bottomTrailingRadius: (!isSentByMe || !isLastInGroup) ? 16 : 4,
                                topTrailingRadius: 16
                            ))
                        
                        if isSentByMe && isLastInGroup {
                            Text("Delivered via P2P")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.trailing, 4)
                        } else if !isSentByMe && isLastInGroup {
                            Text(message.timestamp.logTimeString)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.leading, 4)
                        }
                    }
                }
                
                if !isSentByMe { Spacer(minLength: 40) }
            }
        }
    }
    
    private func isSystemLocationEvent(_ type: P2PMessageType) -> Bool {
        return type == .locationRequest ||
               type == .locationResponse ||
               type == .locationSharingStarted ||
               type == .locationSharingStopped ||
               type == .relativePosition ||
               type == .locationExpired
    }
    
    private func systemLocationEventIcon(_ type: P2PMessageType) -> String {
        switch type {
        case .locationRequest: return "questionmark.circle.fill"
        case .locationResponse: return "checkmark.circle.fill"
        case .locationSharingStarted: return "location.fill"
        case .locationSharingStopped: return "location.slash.fill"
        case .relativePosition: return "safari.fill"
        case .locationExpired: return "clock.fill"
        default: return "info.circle.fill"
        }
    }
    
    // MARK: - Unauthorized Banner
    private var unauthorizedBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.raised.slash.fill")
                .font(.system(size: 24))
                .foregroundColor(.red)
            Text("Friend Request Declined")
                .font(.headline)
            Text("You cannot message this person unless they accept a new request.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.systemGray6))
    }
    
    // MARK: - Floating Native iMessage Input Dock
    private var iMessageInputDock: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // (+) Attachment Menu with Share Location Action
            Menu {
                Button(action: {
                    HapticsManager.shared.mediumImpact()
                    viewModel.sendLocationMessage(in: currentConversation)
                }) {
                    Label("Share Current Location", systemImage: "location.fill")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(UIColor.systemGray2))
            }
            
            // iMessage Rounded Input Field
            HStack {
                TextField("iMessage", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 16))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(Color(UIColor.systemGray6))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color(UIColor.systemGray4), lineWidth: 0.5)
            )
            
            // Send Arrow Button (Gradient Accent)
            Button(action: {
                viewModel.sendMessageToConversation(inputText, in: currentConversation)
                inputText = ""
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(UIColor.systemGray3) : AppTheme.tintColor)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }
}

// Custom Corner Shape Helper for bubble corners
struct CustomCornerShape: Shape {
    var radius: CGFloat = 16
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

#Preview {
    ChatView(
        viewModel: MessagesViewModel(multipeerService: MultipeerService.shared, locationService: LocationService.shared),
        conversation: Conversation(id: "1", displayName: "Aditya", recipientNodeID: "10000000-0000-0000-0000-000000000000", isOnline: true, lastMessage: "Hello", lastTimestamp: "10:00 AM", messages: [])
    )
}


