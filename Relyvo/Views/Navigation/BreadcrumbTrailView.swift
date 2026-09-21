//
//  BreadcrumbTrailView.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import SwiftUI
import CoreLocation

/// View displaying user GPS breadcrumb tracks, recording controls, elevation, and "Return-to-Start" action
struct BreadcrumbTrailView: View {
    @StateObject private var viewModel = BreadcrumbViewModel()
    @State private var activeNavTarget: NavigationTarget?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                // Active Recording Status Card
                Section {
                    VStack(spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(viewModel.isTracking ? "RECORDING ACTIVE TRAIL" : "BREADCRUMB TRACKING IDLE")
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .foregroundColor(viewModel.isTracking ? .green : .gray)
                                
                                if let active = viewModel.activeTrack {
                                    Text(active.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                }
                            }
                            Spacer()
                            
                            if viewModel.isTracking {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(Color.green.opacity(0.4), lineWidth: 4))
                            }
                        }
                        
                        if viewModel.isTracking {
                            HStack(spacing: 20) {
                                VStack(alignment: .leading) {
                                    Text("DISTANCE")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.gray)
                                    Text(viewModel.formattedDistance)
                                        .font(.title3.bold())
                                }
                                
                                VStack(alignment: .leading) {
                                    Text("DURATION")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.gray)
                                    Text(viewModel.formattedDuration)
                                        .font(.title3.bold())
                                }
                                
                                VStack(alignment: .leading) {
                                    Text("WAYPOINTS")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(.gray)
                                    Text("\(viewModel.recordedPoints.count)")
                                        .font(.title3.bold())
                                }
                            }
                        }
                        
                        HStack(spacing: 10) {
                            if viewModel.isTracking {
                                Button(role: .destructive, action: { viewModel.stopTracking() }) {
                                    Label("Stop Trail", systemImage: "stop.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                
                                Button(action: {
                                    if let target = viewModel.returnToStartTarget() {
                                        self.activeNavTarget = target
                                    }
                                }) {
                                    Label("Return to Start", systemImage: "arrow.uturn.backward")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button(action: { viewModel.startTracking() }) {
                                    Label("Start Recording Trail", systemImage: "record.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                
                // Historical Saved Tracks
                Section("Saved Trails (\(viewModel.allTracks.count))") {
                    if viewModel.allTracks.isEmpty {
                        Text("No recorded GPS trails yet. Tap 'Start Recording Trail' to track your movement offline.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        ForEach(viewModel.allTracks, id: \.id) { track in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(track.name)
                                        .font(.subheadline.bold())
                                    Spacer()
                                    Text(track.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.gray)
                                }
                                
                                HStack(spacing: 12) {
                                    Text("Length: \(String(format: "%.0f m", track.totalDistanceMeters))")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Text("Points: \(track.pointsCount)")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    
                                    Spacer()
                                    
                                    Button("Backtrack") {
                                        if let startLat = track.startLatitude, let startLon = track.startLongitude {
                                            let target = NavigationTarget(
                                                id: "track_origin_\(track.id)",
                                                displayName: "Origin: \(track.name)",
                                                coordinate: CLLocationCoordinate2D(latitude: startLat, longitude: startLon),
                                                targetType: .returnToStart
                                            )
                                            self.activeNavTarget = target
                                        }
                                    }
                                    .font(.caption.bold())
                                    .buttonStyle(.bordered)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    viewModel.deleteTrack(track)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Breadcrumb Trails")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: $activeNavTarget) { target in
                OfflineNavigationView(target: target)
            }
        }
    }
}
