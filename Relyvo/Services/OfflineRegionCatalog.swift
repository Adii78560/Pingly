import Foundation
import CoreLocation

/// Represents a downloadable or available region in the catalog.
struct CatalogRegion: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let version: String
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double
    let estimatedSizeBytes: Int64
    
    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2.0,
            longitude: (minLongitude + maxLongitude) / 2.0
        )
    }
}

/// Catalog containing all known regions that Relyvo supports globally.
struct OfflineRegionCatalog: Sendable {
    let availableRegions: [CatalogRegion]
    
    init() {
        self.availableRegions = [
            CatalogRegion(
                id: "monaco",
                displayName: "Monaco",
                version: "1",
                minLatitude: 43.7,
                maxLatitude: 43.8,
                minLongitude: 7.4,
                maxLongitude: 7.5,
                estimatedSizeBytes: 12_000_000
            ),
            CatalogRegion(
                id: "region_punjab",
                displayName: "Punjab Tactical Map",
                version: "1",
                minLatitude: 29.5,
                maxLatitude: 32.5,
                minLongitude: 73.8,
                maxLongitude: 76.9,
                estimatedSizeBytes: 148_000_000
            ),
            CatalogRegion(
                id: "region_delhi_ncr",
                displayName: "Delhi NCR Emergency Sector",
                version: "1",
                minLatitude: 28.2,
                maxLatitude: 28.9,
                minLongitude: 76.8,
                maxLongitude: 77.5,
                estimatedSizeBytes: 112_000_000
            ),
            CatalogRegion(
                id: "region_himachal",
                displayName: "Himachal Mountain Grid",
                version: "1",
                minLatitude: 30.3,
                maxLatitude: 33.3,
                minLongitude: 75.5,
                maxLongitude: 79.0,
                estimatedSizeBytes: 210_000_000
            ),
            CatalogRegion(
                id: "region_california",
                displayName: "California Grid Sector",
                version: "1",
                minLatitude: 32.5,
                maxLatitude: 42.0,
                minLongitude: -124.5,
                maxLongitude: -114.1,
                estimatedSizeBytes: 295_000_000
            )
        ]
    }
}
