import Foundation
import CoreLocation
import Combine
import os

/// State of an installation task
enum RegionInstallState: Equatable {
    case idle
    case loading
    case installing(phase: OfflineInstallPhase)
    case success
    case failed(String)
}

@MainActor
final class OfflineRegionInstallerViewModel: ObservableObject {
    
    // Core Dependencies
    private let regionManager: OfflineRegionManager
    private let installer: OfflineRegionPackageInstaller
    private let catalog: OfflineRegionCatalog
    private let suggestionService: RegionSuggestionService
    private let locationService: LocationService
    
    // Published UI State
    @Published private(set) var installedRegions: [InstalledRoutingRegion] = []
    @Published private(set) var availableRegions: [CatalogRegion] = []
    @Published private(set) var recommendedRegions: [CatalogRegion] = []
    @Published private(set) var installState: RegionInstallState = .idle
    @Published private(set) var isRefreshing: Bool = false
    
    // Subscriptions
    private var cancellables = Set<AnyCancellable>()
    
    init(
        regionManager: OfflineRegionManager? = nil,
        installer: OfflineRegionPackageInstaller? = nil,
        catalog: OfflineRegionCatalog? = nil,
        suggestionService: RegionSuggestionService? = nil,
        locationService: LocationService? = nil
    ) {
        self.regionManager = regionManager ?? .shared
        self.installer = installer ?? .shared
        let resolvedCatalog = catalog ?? OfflineRegionCatalog()
        self.catalog = resolvedCatalog
        self.suggestionService = suggestionService ?? RegionSuggestionService(catalog: resolvedCatalog)
        self.locationService = locationService ?? .shared
        
        self.availableRegions = resolvedCatalog.availableRegions
        
        setupSubscriptions()
    }
    
    private func setupSubscriptions() {
        // When location updates, recalculate recommendations
        locationService.$currentCoordinate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] coordinate in
                self?.updateRecommendations(for: coordinate)
            }
            .store(in: &cancellables)
    }
    
    func refreshData() {
        isRefreshing = true
        Task {
            await regionManager.refreshRegions()
            let regions = await regionManager.installedRegions
            
            await MainActor.run {
                self.installedRegions = regions
                if let currentLoc = self.locationService.currentCoordinate {
                    self.updateRecommendations(for: currentLoc)
                }
                self.isRefreshing = false
            }
        }
    }
    
    private func updateRecommendations(for coordinate: CLLocationCoordinate2D?) {
        guard let coordinate = coordinate else {
            recommendedRegions = []
            return
        }
        
        // Suggest regions, excluding those that are already installed
        let suggestions = suggestionService.suggestRegions(near: coordinate, maxResults: 3)
        let installedIDs = Set(installedRegions.map { $0.id })
        
        recommendedRegions = suggestions.filter { !installedIDs.contains($0.id) }
    }
    
    func isInstalled(_ catalogRegion: CatalogRegion) -> Bool {
        return installedRegions.contains(where: { $0.id == catalogRegion.id })
    }
    
    func getInstalledVersion(for catalogRegion: CatalogRegion) -> String? {
        return installedRegions.first(where: { $0.id == catalogRegion.id })?.version
    }
    
    // MARK: - Actions
    
    func installRegion(_ region: CatalogRegion) {
        installState = .loading
        
        Task {
            do {
                // Generate a mock package for the UI demonstration since remote download isn't supported
                let mockPackageURL = try await generateMockPackage(for: region)
                
                try await installer.installRegionPackage(from: mockPackageURL) { phase in
                    Task { @MainActor in
                        self.installState = .installing(phase: phase)
                    }
                }
                
                await MainActor.run {
                    self.installState = .success
                    self.refreshData()
                }
                
            } catch let error as OfflineRegionError {
                await MainActor.run {
                    self.installState = .failed(error.localizedDescription)
                }
            } catch {
                await MainActor.run {
                    self.installState = .failed(error.localizedDescription)
                }
            }
        }
    }
    
    func removeRegion(_ regionID: String) {
        Task {
            do {
                try await regionManager.deleteRegion(id: regionID)
                await MainActor.run {
                    self.refreshData()
                }
            } catch {
                // In a production app, we would surface this error
            }
        }
    }
    
    func resetState() {
        installState = .idle
    }
    
    // MARK: - Mock Generator
    
    /// Generates a local mock package to simulate a network download for the UI milestone
    private func generateMockPackage(for catalogRegion: CatalogRegion) async throws -> URL {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).relyvoregion")
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Use the bundled monaco if it exists for testing, otherwise just a dummy DB
        let sourceDBPath = Bundle.main.path(forResource: "custom_extract.rgraph", ofType: "sqlite")
        let dbDestPath = tempDir.appendingPathComponent("routing.rgraph.sqlite")
        
        if let source = sourceDBPath, fileManager.fileExists(atPath: source) {
            try fileManager.copyItem(atPath: source, toPath: dbDestPath.path)
            
            // Fix the database schema graph_version for validation
            #if targetEnvironment(macCatalyst) || os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [dbDestPath.path, "UPDATE metadata SET value = '\(catalogRegion.version)' WHERE key = 'graph_version';"]
            try process.run()
            process.waitUntilExit()
            #endif
        } else {
            // Create dummy sqlite structure that passes validation
            let sqliteData = "SQLite format 3\0".data(using: .utf8)!
            try sqliteData.write(to: dbDestPath)
        }
        
        // Generate Manifest
        let manifestDict: [String: Any] = [
            "regionId": catalogRegion.id,
            "version": catalogRegion.version,
            "formatVersion": 1,
            "minLatitude": catalogRegion.minLatitude,
            "maxLatitude": catalogRegion.maxLatitude,
            "minLongitude": catalogRegion.minLongitude,
            "maxLongitude": catalogRegion.maxLongitude,
            "routingDatabase": "routing.rgraph.sqlite",
            "routingChecksum": "mock-checksum" // In a real app we'd compute the sha256
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestDict)
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))
        
        // Add fake delay to simulate network transfer
        try await Task.sleep(nanoseconds: 1_500_000_000)
        
        return tempDir
    }
}
