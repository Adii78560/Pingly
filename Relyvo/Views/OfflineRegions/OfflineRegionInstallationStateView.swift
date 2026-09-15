import SwiftUI

struct OfflineRegionInstallationStateView: View {
    let state: RegionInstallState
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            switch state {
            case .idle:
                EmptyView()
                
            case .loading:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.tintColor))
                    .scaleEffect(1.5)
                Text("Preparing...")
                    .font(.headline)
                
            case .installing(let phase):
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.tintColor))
                    .scaleEffect(1.5)
                
                VStack(spacing: 8) {
                    Text(phaseText(for: phase))
                        .font(.headline)
                        .transition(.opacity)
                        .id(phase.rawValue)
                    
                    Text("Please do not close the app.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .frame(width: 60, height: 60)
                    .foregroundColor(.green)
                
                VStack(spacing: 8) {
                    Text("Installation Complete")
                        .font(.title3.bold())
                    Text("The offline region is now ready for navigation.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                Button(action: onDismiss) {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(AppTheme.tintColor)
                        .cornerRadius(12)
                }
                .padding(.top, 16)
                
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle.fill")
                    .resizable()
                    .frame(width: 60, height: 60)
                    .foregroundColor(.red)
                
                VStack(spacing: 8) {
                    Text("Installation Failed")
                        .font(.title3.bold())
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                }
                .padding(.top, 16)
            }
        }
        .padding(32)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(24)
        .shadow(radius: 10)
        .padding()
        .animation(.default, value: state)
    }
    
    private func phaseText(for phase: OfflineInstallPhase) -> String {
        switch phase {
        case .preparing: return "Preparing region..."
        case .validating: return "Validating package integrity..."
        case .installing: return "Installing offline maps..."
        case .activating: return "Activating navigation data..."
        }
    }
}
