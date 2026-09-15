import SwiftUI

struct OfflineRegionsView: View {
    @StateObject private var viewModel = OfflineRegionInstallerViewModel()
    
    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).edgesIgnoringSafeArea(.all)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    if viewModel.isRefreshing {
                        HStack {
                            Spacer()
                            ProgressView("Scanning local packages...")
                            Spacer()
                        }
                        .padding()
                    }
                    
                    if !viewModel.recommendedRegions.isEmpty {
                        sectionHeader(title: "Recommended Near You", subtitle: "Based on your current location")
                        
                        ForEach(viewModel.recommendedRegions) { region in
                            NavigationLink(destination: OfflineRegionDetailView(region: region, viewModel: viewModel)) {
                                OfflineRegionCardView(
                                    region: region,
                                    isInstalled: viewModel.isInstalled(region),
                                    installedVersion: viewModel.getInstalledVersion(for: region),
                                    isRecommended: true
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    
                    if !viewModel.installedRegions.isEmpty {
                        sectionHeader(title: "Installed Regions", subtitle: "Available for offline maps and routing")
                        
                        let installedCatalogRegions = viewModel.availableRegions.filter { viewModel.isInstalled($0) }
                        
                        ForEach(installedCatalogRegions) { region in
                            NavigationLink(destination: OfflineRegionDetailView(region: region, viewModel: viewModel)) {
                                OfflineRegionCardView(
                                    region: region,
                                    isInstalled: true,
                                    installedVersion: viewModel.getInstalledVersion(for: region),
                                    isRecommended: false
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    } else {
                        emptyInstalledState
                    }
                    
                    sectionHeader(title: "Available Regions", subtitle: "All regions in the catalog")
                    
                    let availableNotInstalled = viewModel.availableRegions.filter { !viewModel.isInstalled($0) && !viewModel.recommendedRegions.contains($0) }
                    
                    ForEach(availableNotInstalled) { region in
                        NavigationLink(destination: OfflineRegionDetailView(region: region, viewModel: viewModel)) {
                            OfflineRegionCardView(
                                region: region,
                                isInstalled: false,
                                installedVersion: nil,
                                isRecommended: false
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Offline Regions")
        .onAppear {
            viewModel.refreshData()
        }
    }
    
    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.bold())
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
    
    private var emptyInstalledState: some View {
        VStack(spacing: 8) {
            Image(systemName: "map.slash")
                .font(.largeTitle)
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            Text("No offline regions installed")
                .font(.headline)
            Text("Install a region to use maps and road navigation without internet.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}
