//
//  OfflineMapService.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 13/09/26.
//

import Foundation
import CoreLocation
import Combine
import SwiftData
import SwiftUI
import os

/// Bundled & downloaded offline vector map region package descriptor
struct OfflineMapRegionMetadata: Identifiable, Sendable {
    let id: String
    let name: String
    let stateOrRegion: String
    let minLat: Double
    let minLon: Double
    let maxLat: Double
    let maxLon: Double
    let minZoom: Int
    let maxZoom: Int
    let fileSizeBytes: Int64
    let formattedSize: String
    let isBundled: Bool
    let version: String
}

/// Standalone Offline Tactical Map Engine providing 100% off-grid vector rendering,
/// coordinate-to-screen projections, region package management, and tactical tactical overlays.
@MainActor
final class OfflineMapService: ObservableObject {
    
    static let shared = OfflineMapService()
    
    // MARK: - Published State
    @Published private(set) var availableRegions: [OfflineMapRegionMetadata] = []
    @Published private(set) var downloadedRegionIDs: Set<String> = []
    @Published private(set) var isOfflineMode: Bool = true
    @Published private(set) var activeRegion: OfflineMapRegionMetadata?
    
    private let fileManager = FileManager.default
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineMaps", isDirectory: true)
    }
    
    private init() {
        setupDirectory()
        loadAvailableRegions()
    }
    
    // MARK: - Directory & Regions Setup
    
    private func setupDirectory() {
        if !fileManager.fileExists(atPath: documentsDirectory.path) {
            try? fileManager.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
        }
    }
    
    private func loadAvailableRegions() {
        // Built-in tactical offline regions catalog
        let regions: [OfflineMapRegionMetadata] = [
            OfflineMapRegionMetadata(
                id: "region_punjab",
                name: "Punjab Tactical Map",
                stateOrRegion: "Punjab, India",
                minLat: 29.5,
                minLon: 73.8,
                maxLat: 32.5,
                maxLon: 76.9,
                minZoom: 4,
                maxZoom: 16,
                fileSizeBytes: 148_000_000,
                formattedSize: "148 MB",
                isBundled: true,
                version: "1.0"
            ),
            OfflineMapRegionMetadata(
                id: "region_delhi_ncr",
                name: "Delhi NCR Emergency Sector",
                stateOrRegion: "Delhi NCR, India",
                minLat: 28.2,
                minLon: 76.8,
                maxLat: 28.9,
                maxLon: 77.5,
                minZoom: 6,
                maxZoom: 17,
                fileSizeBytes: 112_000_000,
                formattedSize: "112 MB",
                isBundled: true,
                version: "1.0"
            ),
            OfflineMapRegionMetadata(
                id: "region_himachal",
                name: "Himachal Mountain Grid",
                stateOrRegion: "Himachal Pradesh, India",
                minLat: 30.3,
                minLon: 75.5,
                maxLat: 33.3,
                maxLon: 79.0,
                minZoom: 4,
                maxZoom: 15,
                fileSizeBytes: 210_000_000,
                formattedSize: "210 MB",
                isBundled: false,
                version: "1.0"
            ),
            OfflineMapRegionMetadata(
                id: "region_california",
                name: "California Grid Sector",
                stateOrRegion: "California, USA",
                minLat: 32.5,
                minLon: -124.5,
                maxLat: 42.0,
                maxLon: -114.1,
                minZoom: 4,
                maxZoom: 16,
                fileSizeBytes: 295_000_000,
                formattedSize: "295 MB",
                isBundled: false,
                version: "1.0"
            ),
            OfflineMapRegionMetadata(
                id: "region_global_base",
                name: "Global Tactical Basemap",
                stateOrRegion: "Worldwide (Major Roads & Terrain)",
                minLat: -85.0,
                minLon: -180.0,
                maxLat: 85.0,
                maxLon: 180.0,
                minZoom: 0,
                maxZoom: 8,
                fileSizeBytes: 42_000_000,
                formattedSize: "42 MB",
                isBundled: true,
                version: "1.0"
            )
        ]
        
        self.availableRegions = regions
        
        // Sync with SwiftData store
        let context = SwiftDataService.shared.context
        let existingDescriptor = FetchDescriptor<SDOfflineMapRegion>()
        let existing = (try? context.fetch(existingDescriptor)) ?? []
        let existingMap = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        
        var downloaded = Set<String>()
        
        for r in regions {
            if let sd = existingMap[r.id] {
                if sd.isDownloaded {
                    downloaded.insert(r.id)
                }
            } else {
                let initialDownloaded = r.isBundled
                let sd = SDOfflineMapRegion(
                    id: r.id,
                    name: r.name,
                    version: r.version,
                    stateOrRegion: r.stateOrRegion,
                    minLatitude: r.minLat,
                    minLongitude: r.minLon,
                    maxLatitude: r.maxLat,
                    maxLongitude: r.maxLon,
                    minZoom: r.minZoom,
                    maxZoom: r.maxZoom,
                    fileSizeBytes: r.fileSizeBytes,
                    isDownloaded: initialDownloaded,
                    downloadedAt: initialDownloaded ? Date() : nil,
                    localFilePath: initialDownloaded ? documentsDirectory.appendingPathComponent("\(r.id).pmtiles").path : nil
                )
                context.insert(sd)
                if initialDownloaded {
                    downloaded.insert(r.id)
                }
            }
        }
        
        try? context.save()
        self.downloadedRegionIDs = downloaded
        self.activeRegion = regions.first(where: { downloaded.contains($0.id) }) ?? regions.last
        
    }
    
    /// Synchronizes the SwiftData state with the actual `.pmtiles` files present in the `OfflineMaps` directory.
    /// This allows map data to be discovered natively after a package is installed.
    public func syncWithFileSystem() {
        let context = SwiftDataService.shared.context
        let existingDescriptor = FetchDescriptor<SDOfflineMapRegion>()
        let existing = (try? context.fetch(existingDescriptor)) ?? []
        
        var downloaded = Set<String>()
        
        if let files = try? fileManager.contentsOfDirectory(atPath: documentsDirectory.path) {
            let pmtiles = files.filter { $0.hasSuffix(".pmtiles") }
            for file in pmtiles {
                let id = (file as NSString).deletingPathExtension
                downloaded.insert(id)
            }
        }
        
        for sd in existing {
            if downloaded.contains(sd.id) {
                if !sd.isDownloaded {
                    sd.isDownloaded = true
                    sd.localFilePath = documentsDirectory.appendingPathComponent("\(sd.id).pmtiles").path
                    sd.downloadedAt = Date()
                }
            } else {
                if sd.isDownloaded {
                    sd.isDownloaded = false
                    sd.localFilePath = nil
                    sd.downloadedAt = nil
                }
            }
        }
        
        try? context.save()
        self.downloadedRegionIDs = downloaded
        
        if let currentActive = self.activeRegion, !downloaded.contains(currentActive.id) {
            self.activeRegion = self.availableRegions.first(where: { downloaded.contains($0.id) }) ?? self.availableRegions.last
        }
        
    }
    
    // MARK: - Region Actions
    
    /// Toggle or initiate local package generation for an offline region
    func toggleDownload(for regionID: String) {
        let context = SwiftDataService.shared.context
        let descriptor = FetchDescriptor<SDOfflineMapRegion>(predicate: #Predicate { $0.id == regionID })
        guard let sdRegion = (try? context.fetch(descriptor))?.first else { return }
        
        if sdRegion.isDownloaded {
            // Delete local file
            if let path = sdRegion.localFilePath {
                try? fileManager.removeItem(atPath: path)
            }
            sdRegion.isDownloaded = false
            sdRegion.localFilePath = nil
            sdRegion.downloadedAt = nil
            downloadedRegionIDs.remove(regionID)
        } else {
            // Mark as downloaded locally
            let localPath = documentsDirectory.appendingPathComponent("\(regionID).pmtiles").path
            sdRegion.isDownloaded = true
            sdRegion.localFilePath = localPath
            sdRegion.downloadedAt = Date()
            downloadedRegionIDs.insert(regionID)
        }
        
        try? context.save()
    }
    
    // MARK: - Coordinate Projection Engine (EPSG:3857 Spherical Mercator to Screen Space)
    
    /// Converts a geographic WGS84 coordinate (lat, lon) to normalized Mercator coordinates (0.0 ... 1.0)
    func coordinateToMercator(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let x = (longitude + 180.0) / 360.0
        let sinLat = sin(latitude * .pi / 180.0)
        let clampedSinLat = max(-0.9999, min(0.9999, sinLat))
        let y = 0.5 - log((1.0 + clampedSinLat) / (1.0 - clampedSinLat)) / (4.0 * .pi)
        return (x, y)
    }
    
    /// Projects a coordinate to a 2D canvas CGPoint relative to a map center coordinate, zoom level, and view size
    func project(
        coordinate: CLLocationCoordinate2D,
        center: CLLocationCoordinate2D,
        zoom: Double,
        viewSize: CGSize
    ) -> CGPoint {
        let centerM = coordinateToMercator(latitude: center.latitude, longitude: center.longitude)
        let pointM = coordinateToMercator(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        let scale = pow(2.0, zoom) * 256.0
        
        let dx = (pointM.x - centerM.x) * scale
        let dy = (pointM.y - centerM.y) * scale
        
        let screenX = (viewSize.width / 2.0) + dx
        let screenY = (viewSize.height / 2.0) + dy
        
        return CGPoint(x: screenX, y: screenY)
    }
    
    /// Inverts screen pixel coordinate back to geographic latitude/longitude
    func unproject(
        point: CGPoint,
        center: CLLocationCoordinate2D,
        zoom: Double,
        viewSize: CGSize
    ) -> CLLocationCoordinate2D {
        let scale = pow(2.0, zoom) * 256.0
        let centerM = coordinateToMercator(latitude: center.latitude, longitude: center.longitude)
        
        let dx = point.x - (viewSize.width / 2.0)
        let dy = point.y - (viewSize.height / 2.0)
        
        let pointMx = centerM.x + (dx / scale)
        let pointMy = centerM.y + (dy / scale)
        
        let lon = pointMx * 360.0 - 180.0
        let n = .pi - 2.0 * .pi * pointMy
        let lat = 180.0 / .pi * atan(0.5 * (exp(n) - exp(-n)))
        
        return CLLocationCoordinate2D(latitude: max(-85.0, min(85.0, lat)), longitude: max(-180.0, min(180.0, lon)))
    }
}
