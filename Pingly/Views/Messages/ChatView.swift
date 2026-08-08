//
//  ChatView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

//
//  ChatView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// Detailed iMessage View conforming strictly to Apple HIG
struct ChatView: View {
    @ObservedObject var viewModel: MessagesViewModel
    let conversation: Conversation
    
    @State private var inputText: String = ""
    @Environment(\.dismiss) private var dismiss
    
    var currentConversation: Conversation {
        viewModel.conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages Scroll Feed
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // Date header badge
                        Text("Today \(Date().logTimeString)")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                        
                        ForEach(currentConversation.messages) { message in
                            let isSentByMe = (message.senderName != currentConversation.displayName)
                            iMessageBubbleRow(message: message, isSentByMe: isSentByMe)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: currentConversation.messages.count) { _ in
                    if let last = currentConversation.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Native iMessage Input Dock
            iMessageInputDock
        }
        .navigationTitle(currentConversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(currentConversation.displayName)
                        .font(.headline)
                    Text("iMessage • P2P Direct")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - iMessage Bubble Row
    private func iMessageBubbleRow(message: Message, isSentByMe: Bool) -> some View {
        HStack {
            if isSentByMe { Spacer(minLength: 50) }
            
            VStack(alignment: isSentByMe ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundColor(isSentByMe ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        isSentByMe ? Color.blue : Color(UIColor.systemGray5)
                    )
                    .clipShape(
                        CustomCornerShape(
                            radius: 18,
                            corners: isSentByMe
                                ? [.topLeft, .topRight, .bottomLeft]
                                : [.topLeft, .topRight, .bottomRight]
                        )
                    )
                
                if isSentByMe {
                    Text("Delivered via P2P")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.trailing, 4)
                }
            }
            
            if !isSentByMe { Spacer(minLength: 50) }
        }
    }
    
    // MARK: - Floating Native iMessage Input Dock
    private var iMessageInputDock: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // (+) Attachment Button
            Button(action: {}) {
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
            
            // Send Arrow Button (Blue)
            Button(action: {
                viewModel.sendMessageToConversation(inputText, in: currentConversation)
                inputText = ""
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color(UIColor.systemGray3) : .blue)
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }
}


// Custom Corner Shape Helper for bubble corners (bottom-right 4px or bottom-left 4px)
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
