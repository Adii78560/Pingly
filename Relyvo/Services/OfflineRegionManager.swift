import Foundation
import CoreLocation
import os

/// Model representing an installed and validated routing database region.
struct InstalledRoutingRegion: Identifiable, Sendable {
    let id: String
    let version: String
    let databaseURL: URL
    
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double
    
    let nodeCount: Int
    let edgeCount: Int
    let installedAt: Date
    
    /// Checks if the given coordinate falls inside this region's bounding box.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        return coordinate.latitude >= minLatitude && coordinate.latitude <= maxLatitude &&
               coordinate.longitude >= minLongitude && coordinate.longitude <= maxLongitude
    }
}

/// Actor responsible for lifecycle management, discovery, and resolution of offline routing databases.
actor OfflineRegionManager {
    static let shared = OfflineRegionManager()
    
    private(set) var installedRegions: [InstalledRoutingRegion] = []
    
    private let baseDirectory: URL
    private let logger = Logger(subsystem: "com.RaiEnterprise.Relyvo", category: "OfflineRegionManager")
    
    /// Dependency-injectable initializer for testing.
    init(baseDirectory: URL? = nil) {
        if let dir = baseDirectory {
            self.baseDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent("OfflineRegions", isDirectory: true)
        }
    }
    
    /// Ensures the OfflineRegions directory exists.
    private func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: baseDirectory.path) {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            logger.info("[OfflineRegionManager] Created OfflineRegions directory at \(self.baseDirectory.path)")
        }
    }
    
    /// Scans the directory, validates databases, and populates `installedRegions`.
    func refreshRegions() async {
        logger.info("[OfflineRegionManager] Scanning regions in \(self.baseDirectory.path)")
        
        do {
            try ensureDirectoryExists()
            let files = try FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.creationDateKey])
            let sqliteFiles = files.filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.contains(".rgraph") }
            
            var discoveredRegions: [String: InstalledRoutingRegion] = [:]
            
            for fileURL in sqliteFiles {
                logger.info("[OfflineRegionManager] Discovered database: \(fileURL.lastPathComponent)")
                
                let db = RoutingDatabase(fileURL: fileURL)
                do {
                    // 1. Validate Schema and Integrity
                    try db.validate()
                    logger.info("[OfflineRegionManager] \(fileURL.lastPathComponent) - Integrity check: PASS, Schema validation: PASS")
                    
                    // 2. Extract Metadata and Region
                    let meta = try db.metadata()
                    let region = try db.region()
                    let creationDate = (try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    
                    let installed = InstalledRoutingRegion(
                        id: meta.regionId,
                        version: meta.graphVersion,
                        databaseURL: fileURL,
                        minLatitude: region.minLat,
                        maxLatitude: region.maxLat,
                        minLongitude: region.minLon,
                        maxLongitude: region.maxLon,
                        nodeCount: meta.nodeCount,
                        edgeCount: meta.edgeCount,
                        installedAt: creationDate
                    )
                    
                    // 3. Handle Duplicates / Versioning
                    if let existing = discoveredRegions[installed.id] {
                        // Simple version comparison (falling back to installedAt if versions are identical/unparseable)
                        if installed.version > existing.version || (installed.version == existing.version && installed.installedAt > existing.installedAt) {
                            discoveredRegions[installed.id] = installed
                            logger.info("[OfflineRegionManager] Upgraded region \(installed.id) to version \(installed.version)")
                            // Mark older for cleanup
                            try? FileManager.default.removeItem(at: existing.databaseURL)
                            logger.info("[OfflineRegionManager] Removed obsolete region file: \(existing.databaseURL.lastPathComponent)")
                        } else {
                            // Current file is older/obsolete, clean it up
                            try? FileManager.default.removeItem(at: fileURL)
                            logger.info("[OfflineRegionManager] Removed obsolete region file: \(fileURL.lastPathComponent)")
                        }
                    } else {
                        discoveredRegions[installed.id] = installed
                        logger.info("[OfflineRegionManager] Registered region: \(installed.id) (v\(installed.version))")
                    }
                    
                } catch {
                    logger.error("[OfflineRegionManager] Rejected \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            
            self.installedRegions = Array(discoveredRegions.values).sorted(by: { $0.id < $1.id })
            logger.info("[OfflineRegionManager] Refresh complete. \(self.installedRegions.count) valid regions available.")
            
        } catch {
            logger.error("[OfflineRegionManager] Failed to scan regions directory: \(error.localizedDescription)")
        }
    }
    
    /// Resolves the most appropriate routing database region for a given coordinate.
    func resolveRegion(for coordinate: CLLocationCoordinate2D) -> InstalledRoutingRegion? {
        let matchingRegions = installedRegions.filter { $0.contains(coordinate) }
        
        if matchingRegions.isEmpty {
            logger.warning("[OfflineRegionManager] No installed region for coordinate (\(coordinate.latitude), \(coordinate.longitude))")
            return nil
        }
        
        // Prefer the newest version among matches (though refreshRegions already deduplicates by ID)
        // If there are overlapping regions with different IDs, just pick the first deterministically (sorted by ID).
        let selected = matchingRegions.first!
        logger.info("[OfflineRegionManager] Resolved coordinate (\(coordinate.latitude), \(coordinate.longitude)) -> region \(selected.id)")
        return selected
    }
    
    /// Resolves the database for a route (validates both start and destination)
    func resolveRegionForRoute(from start: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) throws -> InstalledRoutingRegion {
        guard let startRegion = resolveRegion(for: start) else {
            throw RoutingError.regionUnavailable
        }
        
        guard let destRegion = resolveRegion(for: destination) else {
            throw RoutingError.regionUnavailable
        }
        
        if startRegion.id != destRegion.id {
            logger.error("[Navigation] Current and destination coordinates belong to different offline regions (\(startRegion.id) vs \(destRegion.id))")
            throw RoutingError.regionUnavailable
        }
        
        return startRegion
    }
    
    /// Removes a specific region manually.
    func deleteRegion(id: String) async throws {
        guard let region = installedRegions.first(where: { $0.id == id }) else { return }
        
        let fileManager = FileManager.default
        
        // Remove routing database
        try? fileManager.removeItem(at: region.databaseURL)
        
        // Remove map file if it exists
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let mapsDirectory = documents.appendingPathComponent("OfflineMaps", isDirectory: true)
        let mapURL = mapsDirectory.appendingPathComponent("\(id).pmtiles")
        try? fileManager.removeItem(at: mapURL)
        
        installedRegions.removeAll(where: { $0.id == id })
        logger.info("[OfflineRegionManager] Deleted region \(id) routing and map files.")
        
        // Synchronize Map Service
        await MainActor.run {
            OfflineMapService.shared.syncWithFileSystem()
        }
    }
}
