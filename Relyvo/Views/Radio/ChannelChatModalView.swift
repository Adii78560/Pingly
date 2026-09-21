import SwiftUI

struct ChannelChatModalView: View {
    @ObservedObject var viewModel: RadioCallViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        if viewModel.chatMessages.isEmpty {
                            // Polished Tactical Empty State
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 48))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                                
                                Text("Channel Frequency Clear")
                                    .font(.headline)
                                
                                Text("Messages sent here are broadcast to all peers tuned to \(viewModel.selectedChannel).")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 260)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                        } else {
                            ForEach(Array(viewModel.chatMessages.enumerated()), id: \.element.id) { index, msg in
                                let isMe = (msg.senderID == NodeIdentity.shared.nodeID || msg.originID == NodeIdentity.shared.nodeID)
                                
                                let isLastInGroup: Bool = {
                                    guard index < viewModel.chatMessages.count - 1 else { return true }
                                    let nextMsg = viewModel.chatMessages[index + 1]
                                    let sameSender = nextMsg.senderID == msg.senderID
                                    let timeDiff = abs(nextMsg.timestamp.timeIntervalSince(msg.timestamp))
                                    return !(sameSender && timeDiff < 60)
                                }()
                                
                                let showAvatar = !isMe && isLastInGroup
                                
                                HStack(alignment: .bottom, spacing: 8) {
                                    if !isMe {
                                        if showAvatar {
                                            CircularAvatarView(senderAlias: msg.senderName, senderID: msg.senderID, size: 32)
                                        } else {
                                            Spacer().frame(width: 32)
                                        }
                                    } else {
                                        Spacer(minLength: 40)
                                    }
                                    
                                    VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
                                        Text(msg.text)
                                            .font(.system(size: 15))
                                            .foregroundColor(isMe ? .white : .primary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 9)
                                            .background(isMe ? AppTheme.tintColor : Color(UIColor.secondarySystemBackground))
                                            .clipShape(UnevenRoundedRectangle(
                                                topLeadingRadius: 16,
                                                bottomLeadingRadius: (isMe || !isLastInGroup) ? 16 : 4,
                                                bottomTrailingRadius: (!isMe || !isLastInGroup) ? 16 : 4,
                                                topTrailingRadius: 16
                                            ))
                                        
                                        if !isMe && isLastInGroup {
                                            HStack(spacing: 4) {
                                                Text(msg.timestamp.logTimeString)
                                                    .font(.system(size: 10, weight: .medium))
                                                
                                                if let lat = msg.latitude, let lon = msg.longitude,
                                                   let info = LocationService.shared.distanceAndBearingFromUser(toLat: lat, lon: lon) {
                                                    Text("• 📍 \(info.distanceFormatted) • \(info.bearingDirection)")
                                                        .font(.system(size: 10, weight: .medium))
                                                }
                                            }
                                            .foregroundColor(.secondary)
                                            .padding(.leading, 4)
                                        }
                                    }
                                    
                                    if !isMe { Spacer(minLength: 40) }
                                }
                                .id(msg.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: viewModel.chatMessages.count) { _ in
                    if let last = viewModel.chatMessages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(viewModel.selectedChannel)
                            .font(.headline)
                        
                        let onlineCount = viewModel.activeChannelMembers.count + 1
                        Text("👥 \(onlineCount) online • Mesh encrypted")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                // Native iOS Input Accessory Dock
                VStack(spacing: 0) {
                    Divider()
                    HStack(spacing: 10) {
                        TextField("Message \(viewModel.selectedChannel)...", text: $viewModel.messageText, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                            .focused($isFocused)
                            .submitLabel(.send)
                            .onSubmit {
                                viewModel.sendChannelTextMessage(viewModel.messageText)
                            }
                        
                        Button(action: {
                            viewModel.sendChannelTextMessage(viewModel.messageText)
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.4) : AppTheme.tintColor)
                        }
                        .disabled(viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
    }
}
