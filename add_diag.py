import sys

with open('Relyvo/Services/PersistenceActor.swift', 'r') as f:
    lines = f.readlines()

new_method = """
    public func performPersistenceReadWriteDiagnosticTest() -> (success: Bool, message: String) {
        AppLogger.multipeer.info("[PersistenceTest] Test started")
        let testID = UUID()
        let testText = "[DIAGNOSTIC_TEST_\\(testID.uuidString.prefix(6))]"
        
        let testMessage = SDChatMessage(
            id: testID,
            originID: "DIAGNOSTIC",
            senderID: "DIAGNOSTIC",
            destinationID: "DIAGNOSTIC",
            senderName: "DiagnosticSystem",
            channel: "DIAGNOSTIC_CHANNEL",
            text: testText,
            timestamp: Date(),
            messageTypeRaw: "TEXT",
            isSynced: true,
            isDelivered: true
        )
        
        // 1. WRITE
        modelContext.insert(testMessage)
        AppLogger.multipeer.info("[PersistenceTest] Test record created")
        
        // 2. SAVE
        do {
            try modelContext.save()
            AppLogger.multipeer.info("[PersistenceTest] Save succeeded")
        } catch {
            AppLogger.multipeer.error("[PersistenceTest][ERROR] TEST FAILED at SAVE stage: \\(error.localizedDescription)")
            return (false, "SAVE failed: \\(error.localizedDescription)")
        }
        
        // 3. FETCH
        let descriptor = FetchDescriptor<SDChatMessage>(
            predicate: #Predicate { $0.id == testID }
        )
        guard let fetched = (try? modelContext.fetch(descriptor))?.first else {
            AppLogger.multipeer.error("[PersistenceTest][ERROR] TEST FAILED at FETCH stage: Record not found")
            return (false, "FETCH failed: Record not found")
        }
        AppLogger.multipeer.info("[PersistenceTest] Fetch succeeded")
        
        // 4. VERIFY
        guard fetched.text == testText && fetched.senderName == "DiagnosticSystem" else {
            AppLogger.multipeer.error("[PersistenceTest][ERROR] TEST FAILED at VERIFY stage: Data mismatch")
            return (false, "VERIFY failed: Record content mismatch")
        }
        AppLogger.multipeer.info("[PersistenceTest] Record verification succeeded")
        
        // 5. DELETE & CLEANUP
        modelContext.delete(fetched)
        do {
            try modelContext.save()
            AppLogger.multipeer.info("[PersistenceTest] Cleanup succeeded")
        } catch {
            return (false, "Cleanup failed: \\(error.localizedDescription)")
        }
        
        return (true, "All stages passed")
    }
"""

# Insert before the last closing brace
for i in range(len(lines)-1, -1, -1):
    if lines[i].strip() == "}":
        lines.insert(i, new_method)
        break

with open('Relyvo/Services/PersistenceActor.swift', 'w') as f:
    f.writelines(lines)
