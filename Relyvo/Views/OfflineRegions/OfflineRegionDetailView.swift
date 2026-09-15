import SwiftUI
import CoreLocation

struct OfflineRegionDetailView: View {
    let region: CatalogRegion
    @ObservedObject var viewModel: OfflineRegionInstallerViewModel
    @Environment(\.dismiss) private var dismiss
    
    private var isInstalled: Bool {
        viewModel.isInstalled(region)
    }
    
    private var installedVersion: String? {
        viewModel.getInstalledVersion(for: region)
    }
    
    private var isUpdateAvailable: Bool {
        if let v = installedVersion {
            return v != region.version // simple string compare for milestone
        }
        return false
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(spacing: 24) {
                    
                    // Header / Coverage Preview
                    VStack(spacing: 8) {
                        coveragePreview
                        
                        Text(region.displayName)
                            .font(.title2.bold())
                            .padding(.top, 16)
                        
                        Text(formattedSize(region.estimatedSizeBytes))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    // Features List
                    VStack(alignment: .leading, spacing: 16) {
                        Text("INCLUDED")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.bottom, -8)
                        
                        featureRow(icon: "map.fill", title: "Offline Maps", subtitle: "Full vector tile rendering without internet")
                        featureRow(icon: "arrow.triangle.turn.up.right.circle.fill", title: "Road Navigation", subtitle: "Turn-by-turn routing")
                        featureRow(icon: "antenna.radiowaves.left.and.right", title: "Off-Grid Compatible", subtitle: "Integrates with mesh location sharing")
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(16)
                    
                    // Status
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STATUS")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text("Installation")
                            Spacer()
                            if isInstalled {
                                Text("Installed (v\(installedVersion ?? ""))")
                                    .foregroundColor(.green)
                            } else {
                                Text("Available (v\(region.version))")
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    
                    // Action Buttons
                    actionButtons
                }
                .padding()
            }
            
            // Installation Overlay
            if viewModel.installState != .idle {
                Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                OfflineRegionInstallationStateView(
                    state: viewModel.installState,
                    onDismiss: { viewModel.resetState() }
                )
            }
        }
        .navigationTitle("Region Details")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    // MARK: - Components
    
    private var coveragePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
                .frame(height: 160)
            
            VStack(spacing: 4) {
                Image(systemName: "map")
                    .font(.largeTitle)
                    .foregroundColor(AppTheme.tintColor)
                    .padding(.bottom, 8)
                
                Text("Coverage Area")
                    .font(.headline)
                
                Text("[\(region.minLatitude, specifier: "%.2f"), \(region.minLongitude, specifier: "%.2f")] to [\(region.maxLatitude, specifier: "%.2f"), \(region.maxLongitude, specifier: "%.2f")]")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func featureRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(AppTheme.tintColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if isInstalled {
                if isUpdateAvailable {
                    Button(action: {
                        viewModel.installRegion(region)
                    }) {
                        Text("Update to v\(region.version)")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(AppTheme.tintColor)
                            .cornerRadius(12)
                    }
                }
                
                Button(action: {
                    dismiss()
                    // Notification to parent UI to transition to navigation
                    NotificationCenter.default.post(name: NSNotification.Name("OpenNavigationTab"), object: nil)
                }) {
                    Text("Start Navigation")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                }
                
                Button(action: {
                    viewModel.removeRegion(region.id)
                    dismiss()
                }) {
                    Text("Remove Region")
                        .font(.headline)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                }
            } else {
                Button(action: {
                    viewModel.installRegion(region)
                }) {
                    Text("Install Region")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AppTheme.tintColor)
                        .cornerRadius(12)
                }
            }
        }
    }
    
    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
