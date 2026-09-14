import os
import re

directory = "/Users/adityarai/Desktop/Pingly/Relyvo"

methods_to_replace = [
    "saveChatMessage",
    "saveVoiceTranscript",
    "saveAudioSegment",
    "saveVoiceMessage",
    "enqueuePendingMessage",
    "savePendingMessage",
    "enqueueRelayMessage",
    "resetFailedPendingMessages",
    "updatePendingMessageStatus",
    "markPendingMessageAsACKed",
    "markTranscriptsAsDelivered",
    "markVoiceMessageAsPlayed",
    "markVoiceMessagesAsDelivered",
    "updateVoiceMessageFilePath"
]

for root, dirs, files in os.walk(directory):
    for file in files:
        if file.endswith(".swift") and file != "SwiftDataService.swift" and file != "PersistenceActor.swift":
            path = os.path.join(root, file)
            with open(path, 'r') as f:
                content = f.read()
            
            original_content = content
            
            for method in methods_to_replace:
                # Replace `_ = SwiftDataService.shared.method(...)` with `Task { await SwiftDataService.shared.persistenceActor.method(...) }`
                # Need to handle multiline. A regex might be complex.
                pass
                
            # Actually, doing it via regex in python is tricky for multiline function calls.
            # Let's just list the files that contain these strings, and I can patch them manually or write a smarter script.
