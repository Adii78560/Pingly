import Foundation
import CoreLocation

/// Suggests relevant offline regions based on geographic location (GPS).
final class RegionSuggestionService: Sendable {
    private let catalog: OfflineRegionCatalog
    
    init(catalog: OfflineRegionCatalog = OfflineRegionCatalog()) {
        self.catalog = catalog
    }
    
    /// Suggests regions that either contain the user's coordinate or are geographically close.
    /// Returns a list of `CatalogRegion` sorted by relevance (containing regions first, then by distance to centroid).
    func suggestRegions(near coordinate: CLLocationCoordinate2D, maxResults: Int = 5) -> [CatalogRegion] {
        let userLoc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        var scoredRegions: [(region: CatalogRegion, isInside: Bool, distance: CLLocationDistance)] = []
        
        for region in catalog.availableRegions {
            let isInside = coordinate.latitude >= region.minLatitude &&
                           coordinate.latitude <= region.maxLatitude &&
                           coordinate.longitude >= region.minLongitude &&
                           coordinate.longitude <= region.maxLongitude
            
            let centerLoc = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
            let distance = userLoc.distance(from: centerLoc)
            
            scoredRegions.append((region: region, isInside: isInside, distance: distance))
        }
        
        // Sort: First regions that contain the point, then by distance to centroid
        scoredRegions.sort { a, b in
            if a.isInside && !b.isInside { return true }
            if !a.isInside && b.isInside { return false }
            return a.distance < b.distance
        }
        
        return Array(scoredRegions.prefix(maxResults).map { $0.region })
    }
}
