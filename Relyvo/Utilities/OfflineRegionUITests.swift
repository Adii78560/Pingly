import Foundation
import CoreLocation

// Assuming we run this as a script
@MainActor
class OfflineRegionUITests {
    func runAllTests() async {
        
        await testInitialStateAndRecommendations()
        await testInstallStateFlow()
        
    }
    
    func testInitialStateAndRecommendations() async {
        // Mock Dependencies
        let catalog = OfflineRegionCatalog()
        let suggestionService = RegionSuggestionService(catalog: catalog)
        let locationService = LocationService.shared
        
        let viewModel = OfflineRegionInstallerViewModel(
            catalog: catalog,
            suggestionService: suggestionService,
            locationService: locationService
        )
        
        // Assert initial
        assert(viewModel.installState == .idle, "Should start idle")
        assert(viewModel.availableRegions.count == catalog.availableRegions.count, "Available regions should match catalog")
        
    }
    
    func testInstallStateFlow() async {
        let catalog = OfflineRegionCatalog()
        let viewModel = OfflineRegionInstallerViewModel(catalog: catalog)
        
        let region = catalog.availableRegions[0]
        
        viewModel.installRegion(region)
        
        assert(viewModel.installState == .loading, "State should be loading initially after calling installRegion")
        
        // Wait for background generation
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        
        // Wait another bit for main actor updates
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        switch viewModel.installState {
        case .success, .failed:
            break
        default:
            fatalError()
        }
    }
}
