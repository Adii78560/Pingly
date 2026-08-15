//
//  MessagesView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

//
//  MessagesView.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Native Apple iMessage Conversation Directory View
struct MessagesView: View {
    @StateObject var viewModel: MessagesViewModel
    @State private var searchText = ""
    @State private var showSOSDialog = false
    
    var filteredConversations: [Conversation] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.conversations
        }
        return viewModel.conversations.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.lastMessage.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if filteredConversations.isEmpty {
                    emptyStateView
                } else {
                    List {
                        ForEach(filteredConversations) { conversation in
                            NavigationLink(destination: ChatView(viewModel: viewModel, conversation: conversation)) {
                                iMessageRow(conversation: conversation)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Messages")
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
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
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.displayName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text(conversation.lastTimestamp)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                
                Text(conversation.lastMessage)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
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
                    Text("Broadcasting an emergency beacon sends high-priority pings to all nearby Relayn mesh nodes.")
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


