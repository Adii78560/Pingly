//
//  TacticalMapView.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import SwiftUI
import CoreLocation
import MultipeerConnectivity

/// Full-screen 100% Offline Tactical Vector Map Renderer
struct TacticalMapView: View {
    @StateObject private var viewModel = TacticalMapViewModel()
    @ObservedObject private var breadcrumbs = BreadcrumbTrackingService.shared
    @State private var dragOffset: CGSize = .zero
    @State private var currentScale: CGFloat = 1.0
    @State private var showLayerMenu: Bool = false
    
    var onSelectTarget: ((NavigationTarget) -> Void)?
    
    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size
            
            ZStack {
                // Tactical Dark Background
                Color(red: 0.05, green: 0.07, blue: 0.09)
                    .ignoresSafeArea()
                
                // Vector Map Canvas Layer
                Canvas { context, size in
                    drawTacticalGrid(context: context, size: size)
                    drawTopoContours(context: context, size: size)
                    
                    if viewModel.showBreadcrumbsLayer {
                        drawBreadcrumbTrail(context: context, size: size)
                    }
                    
                    if viewModel.showTargetLayer, let target = viewModel.activeTarget, let userCoord = viewModel.userCoordinate {
                        drawLineOfSight(context: context, size: size, from: userCoord, to: target)
                    }
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let dx = Double(value.translation.width - dragOffset.width)
                            let dy = Double(value.translation.height - dragOffset.height)
                            viewModel.pan(dx: dx, dy: dy, viewSize: viewSize)
                            dragOffset = value.translation
                        }
                        .onEnded { _ in
                            dragOffset = .zero
                        }
                )
                
                // Interactive Node Overlay Layer
                ZStack {
                    // 1. Breadcrumb Start Pin
                    if viewModel.showBreadcrumbsLayer, let firstPoint = breadcrumbs.recordedPoints.first {
                        let pos = OfflineMapService.shared.project(
                            coordinate: CLLocationCoordinate2D(latitude: firstPoint.latitude, longitude: firstPoint.longitude),
                            center: viewModel.centerCoordinate,
                            zoom: viewModel.zoomLevel,
                            viewSize: viewSize
                        )
                        if isVisible(point: pos, in: viewSize) {
                            Circle()
                                .fill(Color.green.opacity(0.8))
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                                .position(pos)
                        }
                    }
                    
                    // 2. Mesh Peers
                    if viewModel.showPeersLayer {
                        ForEach(viewModel.meshPeers) { peer in
                            let peerKey = peer.mcPeerID?.displayName ?? peer.displayName
                            if let session = LocationShareManager.shared.getSession(for: peerKey),
                               let lat = session.lastRemoteLatitude, let lon = session.lastRemoteLongitude {
                                let pos = OfflineMapService.shared.project(
                                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                    center: viewModel.centerCoordinate,
                                    zoom: viewModel.zoomLevel,
                                    viewSize: viewSize
                                )
                                if isVisible(point: pos, in: viewSize) {
                                    VStack(spacing: 2) {
                                        Image(systemName: "person.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(.cyan)
                                            .background(Circle().fill(Color.black))
                                        Text(peer.displayName)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.black.opacity(0.7)))
                                    }
                                    .position(pos)
                                    .onTapGesture {
                                        let target = NavigationTarget(
                                            id: peerKey,
                                            displayName: peer.displayName,
                                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                            targetType: .peer
                                        )
                                        onSelectTarget?(target)
                                    }
                                }
                            }
                        }
                    }
                    
                    // 3. Active Target Marker
                    if viewModel.showTargetLayer, let target = viewModel.activeTarget {
                        let pos = OfflineMapService.shared.project(
                            coordinate: target.coordinate,
                            center: viewModel.centerCoordinate,
                            zoom: viewModel.zoomLevel,
                            viewSize: viewSize
                        )
                        if isVisible(point: pos, in: viewSize) {
                            VStack(spacing: 3) {
                                ZStack {
                                    Circle()
                                        .stroke(target.targetType == .sos ? Color.red : Color.orange, lineWidth: 2)
                                        .frame(width: 28, height: 28)
                                    Image(systemName: target.targetType.iconName)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundColor(target.targetType == .sos ? .red : .orange)
                                }
                                Text(target.displayName.uppercased())
                                    .font(.system(size: 10, weight: .black, design: .monospaced))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(target.targetType == .sos ? Color.red.opacity(0.8) : Color.orange.opacity(0.8)))
                            }
                            .position(pos)
                        }
                    }
                    
                    // 4. "YOU" Node with Heading Cone and Accuracy Ring
                    if viewModel.showUserLayer, let userCoord = viewModel.userCoordinate {
                        let pos = OfflineMapService.shared.project(
                            coordinate: userCoord,
                            center: viewModel.centerCoordinate,
                            zoom: viewModel.zoomLevel,
                            viewSize: viewSize
                        )
                        if isVisible(point: pos, in: viewSize) {
                            ZStack {
                                // GPS Accuracy Circle
                                let meterPerPixel = 156543.03392 * cos(userCoord.latitude * .pi / 180) / pow(2.0, viewModel.zoomLevel)
                                let radiusPixels = CGFloat(viewModel.userAccuracy / max(0.01, meterPerPixel))
                                Circle()
                                    .fill(Color.blue.opacity(0.12))
                                    .frame(width: max(16, radiusPixels * 2), height: max(16, radiusPixels * 2))
                                
                                // Heading Cone
                                HeadingConeShape()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.blue.opacity(0.4), Color.blue.opacity(0.0)],
                                            startPoint: .center,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(width: 60, height: 60)
                                    .rotationEffect(.degrees(viewModel.userHeading))
                                
                                // User Core Beacon
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                    .shadow(color: .blue.opacity(0.8), radius: 6)
                            }
                            .position(pos)
                        }
                    }
                }
                
                // Top HUD Bar: Offline Badge & Coordinates
                VStack {
                    HStack {
                        // Offline Status Pill
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                            Text("OFFLINE TACTICAL MAP")
                                .font(.system(size: 10, weight: .black, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        
                        Spacer()
                        
                        // Zoom Level Indicator
                        Text(String(format: "ZOOM: %.1fX", viewModel.zoomLevel))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.75)))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    
                    Spacer()
                }
                
                // Floating Tactical Map Controls
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            // Center on You
                            Button(action: { viewModel.centerOnUser() }) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(viewModel.isFollowingUser ? .blue : .white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Color(red: 0.12, green: 0.15, blue: 0.18)))
                                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            }
                            
                            // Center on Target
                            if viewModel.activeTarget != nil {
                                Button(action: { viewModel.centerOnTarget() }) {
                                    Image(systemName: "target")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.orange)
                                        .frame(width: 44, height: 44)
                                        .background(Circle().fill(Color(red: 0.12, green: 0.15, blue: 0.18)))
                                        .overlay(Circle().stroke(Color.orange.opacity(0.4), lineWidth: 1))
                                }
                            }
                            
                            // Zoom In
                            Button(action: { viewModel.zoomIn() }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Color(red: 0.12, green: 0.15, blue: 0.18)))
                                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            }
                            
                            // Zoom Out
                            Button(action: { viewModel.zoomOut() }) {
                                Image(systemName: "minus")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Color(red: 0.12, green: 0.15, blue: 0.18)))
                                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            }
                            
                            // Layers Toggle
                            Button(action: { showLayerMenu.toggle() }) {
                                Image(systemName: "square.3.layers.3d")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Circle().fill(Color(red: 0.12, green: 0.15, blue: 0.18)))
                                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            }
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 30)
                    }
                }
            }
            .sheet(isPresented: $showLayerMenu) {
                MapLayersSheet(viewModel: viewModel)
                    .presentationDetents([.medium])
            }
        }
    }
    
    // MARK: - Canvas Drawing Subroutines
    
    private func drawTacticalGrid(context: GraphicsContext, size: CGSize) {
        guard viewModel.showGridLayer else { return }
        
        var gridPath = Path()
        let step: CGFloat = 60.0
        
        var x: CGFloat = 0
        while x <= size.width {
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        
        var y: CGFloat = 0
        while y <= size.height {
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        
        context.stroke(gridPath, with: .color(Color.white.opacity(0.04)), lineWidth: 1)
    }
    
    private func drawTopoContours(context: GraphicsContext, size: CGSize) {
        guard viewModel.showTopoContours else { return }
        // Subtle topological altitude elevation line curves
        var topoPath = Path()
        let waveCount = 5
        for i in 0..<waveCount {
            let baseY = size.height * CGFloat(i + 1) / CGFloat(waveCount + 1)
            topoPath.move(to: CGPoint(x: 0, y: baseY))
            topoPath.addQuadCurve(
                to: CGPoint(x: size.width, y: baseY + 15 * sin(Double(i))),
                control: CGPoint(x: size.width / 2, y: baseY - 30 * cos(Double(i)))
            )
        }
        context.stroke(topoPath, with: .color(Color.teal.opacity(0.06)), lineWidth: 1)
    }
    
    private func drawBreadcrumbTrail(context: GraphicsContext, size: CGSize) {
        let points = breadcrumbs.recordedPoints
        guard points.count >= 2 else { return }
        
        var trailPath = Path()
        var isFirst = true
        
        for pt in points {
            let projected = OfflineMapService.shared.project(
                coordinate: CLLocationCoordinate2D(latitude: pt.latitude, longitude: pt.longitude),
                center: viewModel.centerCoordinate,
                zoom: viewModel.zoomLevel,
                viewSize: size
            )
            if isFirst {
                trailPath.move(to: projected)
                isFirst = false
            } else {
                trailPath.addLine(to: projected)
            }
        }
        
        context.stroke(trailPath, with: .color(Color.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
    
    private func drawLineOfSight(context: GraphicsContext, size: CGSize, from user: CLLocationCoordinate2D, to target: NavigationTarget) {
        let userPos = OfflineMapService.shared.project(
            coordinate: user,
            center: viewModel.centerCoordinate,
            zoom: viewModel.zoomLevel,
            viewSize: size
        )
        let targetPos = OfflineMapService.shared.project(
            coordinate: target.coordinate,
            center: viewModel.centerCoordinate,
            zoom: viewModel.zoomLevel,
            viewSize: size
        )
        
        var line = Path()
        line.move(to: userPos)
        line.addLine(to: targetPos)
        
        let strokeColor = target.targetType == .sos ? Color.red.opacity(0.8) : Color.orange.opacity(0.8)
        context.stroke(line, with: .color(strokeColor), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
    }
    
    private func isVisible(point: CGPoint, in size: CGSize) -> Bool {
        return point.x >= -50 && point.x <= size.width + 50 && point.y >= -50 && point.y <= size.height + 50
    }
}

/// Shape representing user's directional heading cone
struct HeadingConeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(
            center: center,
            radius: rect.width / 2,
            startAngle: .degrees(-120),
            endAngle: .degrees(-60),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// Tactical Map Layers Configuration Sheet
struct MapLayersSheet: View {
    @ObservedObject var viewModel: TacticalMapViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section("Tactical Map Overlays") {
                    Toggle("My Location Node", isOn: $viewModel.showUserLayer)
                    Toggle("Navigation Target", isOn: $viewModel.showTargetLayer)
                    Toggle("Mesh Peers (BLE & Wi-Fi)", isOn: $viewModel.showPeersLayer)
                    Toggle("Emergency SOS Layer", isOn: $viewModel.showSOSLayer)
                    Toggle("Breadcrumb GPS Trail", isOn: $viewModel.showBreadcrumbsLayer)
                    Toggle("MGRS Tactical Grid", isOn: $viewModel.showGridLayer)
                    Toggle("Topographic Contours", isOn: $viewModel.showTopoContours)
                }
                
                Section("Offline Region Packages") {
                    ForEach(OfflineMapService.shared.availableRegions) { region in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(region.name)
                                    .font(.subheadline.bold())
                                Text("\(region.stateOrRegion) • \(region.formattedSize)")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            if OfflineMapService.shared.downloadedRegionIDs.contains(region.id) {
                                Label("Loaded", systemImage: "checkmark.circle.fill")
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                            } else {
                                Button("Download") {
                                    OfflineMapService.shared.toggleDownload(for: region.id)
                                }
                                .font(.caption.bold())
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Map Layers & Regions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
