//
//  UsernameGenerator.swift
//  Pingly
//
//  Created by Senior iOS Developer on 13/08/26.
//

import Foundation

/// Atomic generator for visually distinct, non-ambiguous 8-character Pingly usernames
final class UsernameGenerator {
    
    /// Unambiguous uppercase alphanumeric character set (excludes O, 0, I, 1)
    private static let safeCharacters: [Character] = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    
    /// Generates a random 8-character Pingly username (e.g. K7M2Q9XP, B4T8N6ZR)
    static func generate8CharUsername() -> String {
        var result = ""
        result.reserveCapacity(8)
        for _ in 0..<8 {
            let randomIndex = Int.random(in: 0..<safeCharacters.count)
            result.append(safeCharacters[randomIndex])
        }
        return result
    }
}
