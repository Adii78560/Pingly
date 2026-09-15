import SwiftUI

struct OfflineRegionCardView: View {
    let region: CatalogRegion
    let isInstalled: Bool
    let installedVersion: String?
    let isRecommended: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(region.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if isRecommended {
                        Text("Recommended for you")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(AppTheme.tintColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(AppTheme.tintColor.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                
                Spacer()
                
                if isInstalled {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                } else {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundColor(AppTheme.tintColor)
                        .font(.title3)
                }
            }
            
            HStack(spacing: 16) {
                Label(formattedSize(region.estimatedSizeBytes), systemImage: "internaldrive")
                Label("Maps & Routing", systemImage: "map")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            if let version = installedVersion {
                Text("Installed Version \(version)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
