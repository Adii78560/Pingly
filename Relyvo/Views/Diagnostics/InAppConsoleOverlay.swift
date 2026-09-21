//
//  InAppConsoleOverlay.swift
//  Relyvo
//
//  Created by Antigravity on 18/09/26.
//

import SwiftUI

/// A floating overlay that displays live validation campaign events across all application screens.
struct InAppConsoleOverlay: View {
    @StateObject private var logger = PhysicalValidationLogger.shared
    @State private var offset: CGSize = .zero
    @State private var isExpanded: Bool = true
    
    var body: some View {
        if logger.isOverlayVisible {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    // Header / Drag Handle
                    HStack {
                        Text("MESH CONSOLE")
                            .font(.caption2.monospaced().bold())
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                        }
                        
                        Button {
                            withAnimation {
                                logger.isOverlayVisible = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption.bold())
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.85))
                    
                    if isExpanded {
                        ScrollViewReader { scrollProxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    if logger.logs.isEmpty {
                                        Text("Waiting for MESH events...")
                                            .font(.caption2.monospaced())
                                            .foregroundColor(.gray)
                                            .padding()
                                    } else {
                                        ForEach(logger.logs) { log in
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(alignment: .top) {
                                                    Text(log.type.rawValue)
                                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                                        .foregroundColor(colorForType(log.type))
                                                    Spacer()
                                                    Text(timeFormatter.string(from: log.timestamp))
                                                        .font(.system(size: 9, design: .monospaced))
                                                        .foregroundColor(.gray)
                                                }
                                                Text(log.message)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundColor(.white)
                                                    .lineLimit(4)
                                            }
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.black.opacity(0.4))
                                            .cornerRadius(4)
                                            .id(log.id)
                                        }
                                    }
                                }
                                .padding(4)
                            }
                            .frame(height: 250)
                            .background(Color.black.opacity(0.75))
                            .onChange(of: logger.logs) { _ in
                                if let last = logger.logs.last {
                                    withAnimation {
                                        scrollProxy.scrollTo(last.id, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(width: proxy.size.width * 0.9)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .position(x: proxy.size.width / 2, y: isExpanded ? proxy.size.height - 180 : proxy.size.height - 80)
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            self.offset = value.translation
                        }
                        .onEnded { value in
                            // Optional: snap back or leave where dropped
                        }
                )
                .ignoresSafeArea(.keyboard)
                .zIndex(999)
            }
        }
    }
    
    private func colorForType(_ type: ValidationEventType) -> Color {
        switch type {
        case .meshRx, .meshDelivered: return .green
        case .meshForward: return .blue
        case .meshDedupDrop, .meshLoopDrop, .meshTtlDrop: return .orange
        case .chatAuthDrop, .chatQueueAuthDrop: return .red
        case .meshAck: return .cyan
        case .meshQueue: return .yellow
        case .peerDiscovered, .peerConnected, .peerDisconnected: return .purple
        }
    }
    
    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
}
