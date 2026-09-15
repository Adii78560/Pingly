import Foundation

/// Errors that can occur during offline region validation and installation.
enum OfflineRegionError: Error, LocalizedError, Equatable {
    case invalidPackage
    case manifestMissing
    case manifestMalformed(String)
    case unsupportedPackageVersion
    case invalidRegionID
    case invalidBounds
    
    case routingDatabaseMissing
    case routingDatabaseCorrupt
    case routingSchemaInvalid
    case routingMetadataMismatch(String)
    
    case mapDataMissing
    case mapDataMismatch
    
    case checksumMismatch(file: String)
    case downgradeRejected
    case installationFailed(String)
    case regionNotFound
    case regionInUse
    
    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "The region package is invalid or inaccessible."
        case .manifestMissing: return "The package manifest.json is missing."
        case .manifestMalformed(let detail): return "The manifest is malformed: \(detail)"
        case .unsupportedPackageVersion: return "The package format version is not supported."
        case .invalidRegionID: return "The region ID is invalid or missing."
        case .invalidBounds: return "The region bounding box is invalid."
        
        case .routingDatabaseMissing: return "The routing database file is missing from the package."
        case .routingDatabaseCorrupt: return "The routing database is corrupt."
        case .routingSchemaInvalid: return "The routing database schema is invalid or incomplete."
        case .routingMetadataMismatch(let detail): return "Routing database metadata does not match manifest: \(detail)"
        
        case .mapDataMissing: return "The referenced map data is missing."
        case .mapDataMismatch: return "The map data does not match the manifest."
        
        case .checksumMismatch(let file): return "Checksum validation failed for \(file). The file may be corrupt or tampered with."
        case .downgradeRejected: return "Older region version cannot replace an installed newer version."
        case .installationFailed(let msg): return "Installation failed: \(msg)"
        case .regionNotFound: return "The specified region was not found."
        case .regionInUse: return "The region is currently in use by the navigation engine."
        }
    }
}
