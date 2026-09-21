import Foundation

/// Defines the expected structure of a `manifest.json` inside a `.relyvoregion` package.
struct OfflineRegionManifest: Codable, Sendable, Equatable {
    let packageFormatVersion: Int
    let regionId: String
    let version: String
    let displayName: String
    
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double
    
    let routingDatabase: String
    let routingChecksum: String?
    
    let mapData: String?
    let mapChecksum: String?
    
    init(
        packageFormatVersion: Int = 1,
        regionId: String,
        version: String,
        displayName: String,
        minLatitude: Double,
        maxLatitude: Double,
        minLongitude: Double,
        maxLongitude: Double,
        routingDatabase: String,
        routingChecksum: String? = nil,
        mapData: String? = nil,
        mapChecksum: String? = nil
    ) {
        self.packageFormatVersion = packageFormatVersion
        self.regionId = regionId
        self.version = version
        self.displayName = displayName
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
        self.routingDatabase = routingDatabase
        self.routingChecksum = routingChecksum
        self.mapData = mapData
        self.mapChecksum = mapChecksum
    }
}
