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
    @State private var showOfflineNavigationView: Bool = false
    @ObservedObject private var locationShareManager = LocationShareManager.shared
    @Environment(\.dismiss) private var dismiss
    
    var currentConversation: Conversation {
        viewModel.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }
    
    private var conversationMessages: [Message] {
        currentConversation.messages.filter { msg in
            !msg.text.contains("LOCATION_PROTOCOL") &&
            !msg.text.contains("\"type\":\"LOCATION_") &&
            msg.type != .location &&
            msg.type != .locationRequest
        }
    }
    
    private var targetNodeID: String {
        currentConversation.recipientNodeID
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Live Location Banner
            locationBanner
            
            // Chat Messages List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(conversationMessages.enumerated()), id: \.element.id) { index, message in
                            let isMe = (message.senderID == NodeIdentity.shared.nodeID || message.originID == NodeIdentity.shared.nodeID)
                            let isLastInGroup = self.checkIfLastInGroup(index: index, messages: conversationMessages, currentMessage: message)
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
                    showOfflineNavigationView = true
                }) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.primaryGradient)
                }
            }
        }
        .confirmationDialog("Location Sharing Options", isPresented: $showLocationOptionsSheet, titleVisibility: .visible) {
            Button("Ask for Location") {
                LocationShareManager.shared.requestLocation(from: targetNodeID, displayName: currentConversation.displayName)
            }
            Button("Share My Location") {
                LocationShareManager.shared.startSharingLocation(with: targetNodeID, displayName: currentConversation.displayName)
            }
            Button("Share Relative Position") {
                LocationShareManager.shared.shareRelativePosition(with: targetNodeID, displayName: currentConversation.displayName)
            }
            Button("Open Precision Finding") {
                showOfflineNavigationView = true
            }
            if locationShareManager.activeSessions[targetNodeID]?.isSharingLocal == true {
                Button("Stop Sharing Location", role: .destructive) {
                    LocationShareManager.shared.stopSharingLocation(with: targetNodeID, displayName: currentConversation.displayName)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showOfflineNavigationView) {
            if let session = locationShareManager.activeSessions[targetNodeID],
               let lat = session.lastRemoteLatitude,
               let lon = session.lastRemoteLongitude {
                let target = NavigationTarget(
                    id: targetNodeID,
                    displayName: currentConversation.displayName,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    timestamp: session.lastRemoteTimestamp ?? Date()
                )
                OfflineNavigationView(target: target)
            } else {
                Text("Location unavailable")
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            showOfflineNavigationView = false
                        }
                    }
            }
        }
    }
    
    // MARK: - Live Location Banner
    @ViewBuilder
    private var locationBanner: some View {
        if let requestName = locationShareManager.pendingIncomingRequests[targetNodeID] {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.15)).frame(width: 32, height: 32)
                    Image(systemName: "location.viewfinder").foregroundColor(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(requestName) requested your location")
                        .font(.subheadline)
                        .bold()
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: { LocationShareManager.shared.respondToLocationRequest(from: targetNodeID, displayName: currentConversation.displayName, accept: false) }) {
                        Text("Decline")
                            .font(.caption).bold()
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
                    }
                    Button(action: { LocationShareManager.shared.respondToLocationRequest(from: targetNodeID, displayName: currentConversation.displayName, accept: true) }) {
                        Text("Share")
                            .font(.caption).bold()
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.green))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            
            Divider()
        } else if let session = locationShareManager.activeSessions[targetNodeID], session.stateRaw != "DENIED" {
            
            let isMutual = session.isSharingLocal && session.isSharingRemote
            let isRequestPending = session.stateRaw == "REQUEST_PENDING"
            
            HStack(spacing: 12) {
                // Left: Icon
                ZStack {
                    if isRequestPending {
                        Circle()
                            .fill(Color.orange.opacity(0.3))
                            .frame(width: 24, height: 24)
                        Image(systemName: "clock.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                    } else {
                        Circle()
                            .fill(Color.green.opacity(0.3))
                            .frame(width: 24, height: 24)
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Image(systemName: "location.fill")
                            .font(.system(size: 14))
                            .foregroundColor(AppTheme.tintColor)
                            .offset(x: 12, y: -8)
                    }
                }
                
                // Center: Titles
                VStack(alignment: .leading, spacing: 2) {
                    if isRequestPending {
                        Text("Location Requested")
                            .font(.subheadline)
                            .bold()
                        Text("Waiting for \(session.remoteDisplayName)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if isMutual {
                        Text("Mutual Location Sharing Active")
                            .font(.subheadline)
                            .bold()
                    } else if session.isSharingLocal {
                        Text("Sharing Your Location")
                            .font(.subheadline)
                            .bold()
                    } else if session.isSharingRemote {
                        Text("\(session.remoteDisplayName) is Sharing Location")
                            .font(.subheadline)
                            .bold()
                    }
                    
                    if !isRequestPending, session.isSharingRemote, let lat = session.lastRemoteLatitude, let lon = session.lastRemoteLongitude, let userCoord = LocationService.shared.currentCoordinate {
                        let distMeters = OfflineNavigationService.shared.calculateDistance(from: userCoord, to: CLLocationCoordinate2D(latitude: lat, longitude: lon))
                        let formattedDist = OfflineNavigationService.shared.formatDistance(meters: distMeters)
                        Text("📍 \(formattedDist) away")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Right: Actions
                if !isRequestPending {
                    HStack(spacing: 8) {
                        if session.isSharingRemote {
                            Button(action: {
                                showOfflineNavigationView = true
                            }) {
                                Text("Find")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.green))
                            }
                        }
                        
                        if session.isSharingLocal {
                            Button(action: {
                                LocationShareManager.shared.stopSharingLocation(with: targetNodeID, displayName: currentConversation.displayName)
                            }) {
                                Text("Stop")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Color.red.opacity(0.15)))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .onTapGesture {
                if session.isSharingRemote {
                    showOfflineNavigationView = true
                }
            }
            
            Divider()
        }
    }
    
    // MARK: - iMessage Bubble Row
    private func iMessageBubbleRow(message: Message, isSentByMe: Bool, isLastInGroup: Bool, showAvatar: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isSystemLocationEvent(message.type) {
                Spacer()
                if message.type == .locationRequest && !isSentByMe && locationShareManager.pendingIncomingRequests.keys.contains(message.senderID) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.orange)
                            Text(message.text)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                        }
                        HStack(spacing: 12) {
                            Button(action: {
                                LocationShareManager.shared.respondToLocationRequest(from: message.senderID, displayName: message.senderName, accept: false)
                            }) {
                                Text("Decline")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color.red.opacity(0.15)))
                            }
                            Button(action: {
                                LocationShareManager.shared.respondToLocationRequest(from: message.senderID, displayName: message.senderName, accept: true)
                            }) {
                                Text("Share Location")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color.green))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .frame(maxWidth: 300)
                } else {
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
                }
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
    
    private func checkIfLastInGroup(index: Int, messages: [Message], currentMessage: Message) -> Bool {
        if index >= messages.count - 1 {
            return true
        }
        let nextMsg = messages[index + 1]
        let sameSender = nextMsg.senderID == currentMessage.senderID
        let timeDiff = abs(nextMsg.timestamp.timeIntervalSince(currentMessage.timestamp))
        return !(sameSender && timeDiff < 60)
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


