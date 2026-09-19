//
//  MessagesView.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Native Apple iMessage Conversation Directory View
struct MessagesView: View {
    @StateObject var viewModel: MessagesViewModel
    @EnvironmentObject var radarViewModel: RadarViewModel
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var featureAccessManager = FeatureAccessManager.shared
    
    @State private var searchText = ""
    @State private var showSOSDialog = false
    @State private var showActivitySheet = false
    @State private var navigationPath = NavigationPath()
    
    var filteredConversations: [Conversation] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.conversations
        }
        return viewModel.conversations.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.lastMessage.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var authorizedConversations: [Conversation] {
        filteredConversations.filter { DirectChatGate.shared.canSendDirectMessage(to: $0.recipientNodeID) }
    }
    
    var pendingRequests: [SDFriend] {
        radarViewModel.friends.filter { $0.status == .requestReceived }
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                ZStack {
                    messagesListView
                    
                    if !subscriptionManager.isPro {
                        ProFeatureLockOverlay(feature: .messaging)
                            .transition(.opacity)
                    }
                }
            }
            .navigationTitle(subscriptionManager.isPro ? "Messages" : "Messages 🔒")
            .navigationDestination(for: Conversation.self) { conversation in
                ChatView(viewModel: viewModel, conversation: conversation)
            }
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        showActivitySheet = true
                    }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.primary)
                            
                            if !pendingRequests.isEmpty {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 10, height: 10)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showSOSDialog = true
                    }) {
                        Image(systemName: "sos.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.red)
                    }
                }
            }
            .sheet(isPresented: $showSOSDialog) {
                sosSheetView
            }
            .sheet(isPresented: $showActivitySheet) {
                activitySheetView
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToDirectMessage"))) { note in
                guard let userInfo = note.userInfo,
                      let peerID = userInfo["peerID"] as? String,
                      let displayName = userInfo["displayName"] as? String else { return }
                
                let conv = viewModel.getOrCreateConversation(peerName: displayName, nodeID: peerID)
                if subscriptionManager.isPro {
                    navigationPath.append(conv)
                } else {
                    featureAccessManager.presentPaywall(for: .messaging)
                }
            }
        }
    }
    
    // MARK: - Activity Sheet
    private var activitySheetView: some View {
        NavigationStack {
            List {
                if !pendingRequests.isEmpty {
                    Section(header: Text("Friend Requests")) {
                        ForEach(pendingRequests, id: \.nodeID) { friend in
                            friendRequestRow(friend: friend)
                        }
                    }
                }
                
                let nearbyFriends = radarViewModel.nearbyPeers.filter { peer in 
                    radarViewModel.friends.contains(where: { $0.nodeID == peer.id && $0.status == .accepted })
                }
                
                if !nearbyFriends.isEmpty {
                    Section(header: Text("Nearby Activity")) {
                        ForEach(nearbyFriends, id: \.id) { peer in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.green.opacity(0.1))
                                    .frame(width: 48, height: 48)
                                    .overlay(
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .foregroundColor(.green)
                                    )
                                
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(peer.displayName)
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Is nearby and active")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                
                Section(header: Text("Location Updates")) {
                    Text("No recent location updates from friends.")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
                
                if pendingRequests.isEmpty && nearbyFriends.isEmpty {
                    Section {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "bell.slash")
                                .font(.system(size: 48))
                                .foregroundColor(Color(UIColor.systemGray3))
                            Text("No Recent Activity")
                                .font(.headline)
                            Text("When friends send requests, share location, or come nearby, it will appear here.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showActivitySheet = false
                    }
                }
            }
        }
    }
    
    private var messagesListView: some View {
        Group {
            if authorizedConversations.isEmpty {
                emptyStateView
            } else {
                List {
                    ForEach(authorizedConversations) { conversation in
                        if subscriptionManager.isPro {
                            NavigationLink(value: conversation) {
                                iMessageRow(conversation: conversation)
                            }
                        } else {
                            Button(action: {
                                featureAccessManager.presentPaywall(for: .messaging)
                            }) {
                                iMessageRow(conversation: conversation)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
    
    // MARK: - Native iMessage Row Specs
    private func iMessageRow(conversation: Conversation) -> some View {
        HStack(spacing: 12) {
            // Initials Avatar Circle
            ZStack {
                Circle()
                    .fill(Color(UIColor.systemGray5))
                    .frame(width: 48, height: 48)
                
                Text(conversation.displayName.initials)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Color(UIColor.systemGray))
                
                // Online Presence Badge
                if conversation.isOnline {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 2))
                        .offset(x: 18, y: 18)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(conversation.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    HStack(spacing: 6) {
                        if conversation.messages.contains(where: { !$0.isRead && $0.senderID != NodeIdentity.shared.nodeID }) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 8, height: 8)
                        }
                        
                        Text(conversation.lastTimestamp)
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                }
                
                Text(conversation.lastMessage)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Friend Request Row
    private func friendRequestRow(friend: SDFriend) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 48, height: 48)
                
                Text(friend.handle.initials)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.blue)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(friend.handle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Wants to connect")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                Button(action: {
                    radarViewModel.acceptFriendRequest(friend.nodeID)
                }) {
                    Text("Accept")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .cornerRadius(16)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    radarViewModel.declineFriendRequest(friend.nodeID)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color(UIColor.systemGray3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Native Empty State
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundColor(Color(UIColor.systemGray3))
            
            Text("No Conversations")
                .font(.title2.bold())
            
            Text("Connect with nearby devices over Wi-Fi & Bluetooth to start messaging offline.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer()
        }
    }
    
    // MARK: - SOS Trigger Sheet
    private var sosSheetView: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(EmergencyStatus.allCases.filter({ $0 != .normal })) { status in
                        Button(action: {
                            viewModel.triggerEmergencySOS(status: status)
                            showSOSDialog = false
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: status.iconName)
                                    .font(.title3)
                                    .foregroundColor(status.themeColor)
                                    .frame(width: 28)
                                
                                Text(status.rawValue)
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Emergency Distress Alert")
                } footer: {
                    Text("Broadcasting an emergency beacon sends high-priority pings to all nearby Relyvo mesh nodes.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Distress Beacon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showSOSDialog = false
                    }
                }
            }
        }
    }
    
}


