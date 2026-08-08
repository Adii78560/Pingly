//
//  RadioCallView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

////
//  RadioCallView.swift
//  Pingly
//
//  Created by Senior iOS Developer on 09/08/26.
//

import SwiftUI

/// watchOS Walkie-Talkie & FaceTime Audio inspired View conforming to Apple HIG
struct RadioCallView: View {
    @StateObject var viewModel: RadioCallViewModel
    @State private var isPttPressedVisual = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Active Channel Menu Bar
                HStack {
                    Menu {
                        ForEach(viewModel.availableChannels, id: \.self) { ch in
                            Button(ch) {
                                viewModel.selectedChannel = ch
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.selectedChannel)
                                .font(.system(size: 14, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(20)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        viewModel.disconnect()
                    }) {
                        Text("Leave")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.12))
                            .cornerRadius(20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                
                // Peer Contact Card
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color(UIColor.secondarySystemGroupedBackground))
                            .frame(width: 56, height: 56)
                        
                        Text(viewModel.connectedPeerName.initials)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.primary)
                        
                        Circle()
                            .stroke(viewModel.isConnected ? Color.green : Color.gray, lineWidth: 2)
                            .frame(width: 60, height: 60)
                    }
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.connectedPeerName)
                            .font(.system(size: 17, weight: .semibold))
                        
                        HStack(spacing: 6) {
                            Text("\(viewModel.connectedPeerRSSI) dBm")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                            
                            Button(action: {
                                viewModel.toggleAddedToMessages()
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: viewModel.isAddedToMessages ? "checkmark" : "plus")
                                    Text(viewModel.isAddedToMessages ? "Saved" : "Add")
                                }
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(viewModel.isAddedToMessages ? .green : .blue)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(16)
                .padding(.horizontal, 16)
                
                Spacer()
                
                // Central watchOS Walkie-Talkie Yellow PTT Dial
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: 170, height: 170)
                    
                    Circle()
                        .fill(viewModel.isPTTPressed ? Color.orange : Color(red: 1.0, green: 0.8, blue: 0.0)) // #FFCC00 Walkie-Talkie Yellow
                        .frame(width: 130, height: 130)
                        .shadow(color: Color.orange.opacity(viewModel.isPTTPressed ? 0.6 : 0.2), radius: 12, x: 0, y: 6)
                    
                    VStack(spacing: 4) {
                        Image(systemName: viewModel.isPTTPressed ? "waveform.and.mic" : "mic.fill")
                            .font(.system(size: 38, weight: .bold))
                        Text(viewModel.isPTTPressed ? "TALKING" : "TALK")
                            .font(.system(size: 14, weight: .black))
                    }
                    .foregroundColor(.black)
                }
                .scaleEffect(isPttPressedVisual || viewModel.isPTTPressed ? 0.94 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPttPressedVisual || viewModel.isPTTPressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !viewModel.isPTTPressed {
                                isPttPressedVisual = true
                                viewModel.startTransmittingVoice()
                            }
                        }
                        .onEnded { _ in
                            isPttPressedVisual = false
                            viewModel.stopTransmittingVoice()
                        }
                )
                
                Spacer()
                
                // Audio Waveform Indicator
                HStack(spacing: 4) {
                    ForEach(0..<14, id: \.self) { index in
                        let height = viewModel.isPTTPressed ? CGFloat.random(in: 8...32) : 6.0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(viewModel.isPTTPressed ? Color.orange : Color.gray.opacity(0.3))
                            .frame(width: 4, height: height)
                            .animation(.easeInOut(duration: 0.15), value: height)
                    }
                }
                .frame(height: 36)
                
                // Live Message Bar
                Text(viewModel.latestTextSnippet)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .lineLimit(1)
                
                // Bottom Call Control Buttons
                HStack(spacing: 16) {
                    Button(action: {
                        HapticManager.heavyImpact()
                        viewModel.disconnect()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "phone.down.fill")
                            Text("End Call")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.red)
                        .cornerRadius(14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .navigationTitle("Walkie-Talkie")
        }
    }
}


