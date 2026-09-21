import sys
import re

def process_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # 1. Replace DispatchQueue.global(qos: .userInitiated).async { with Task { in MultipeerService.swift
    if "MultipeerService.swift" in filepath:
        content = content.replace("DispatchQueue.global(qos: .userInitiated).async {", "Task {")
    
    # 2. Replace _ = SwiftDataService.shared.method( with await SwiftDataService.shared.persistenceActor.method(
    # Also replace let x = SwiftDataService.shared.method( with let x = await SwiftDataService.shared.persistenceActor.method(
    # Also replace SwiftDataService.shared.method( with await SwiftDataService.shared.persistenceActor.method(
    
    methods = [
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
    
    for method in methods:
        # Pattern 1: _ = SwiftDataService.shared.method(
        content = re.sub(r'_\s*=\s*SwiftDataService\.shared\.' + method + r'\(', r'await SwiftDataService.shared.persistenceActor.' + method + '(', content)
        # Pattern 2: let x = SwiftDataService.shared.method(
        content = re.sub(r'(let\s+\w+\s*=\s*)SwiftDataService\.shared\.' + method + r'\(', r'\1await SwiftDataService.shared.persistenceActor.' + method + '(', content)
        # Pattern 3: SwiftDataService.shared.method( (where no assignment happens)
        content = re.sub(r'(?<!await )SwiftDataService\.shared\.' + method + r'\(', r'await SwiftDataService.shared.persistenceActor.' + method + '(', content)
        
    # Fix instances where we might have double await
    content = content.replace("await await", "await")

    with open(filepath, 'w') as f:
        f.write(content)

if __name__ == "__main__":
    for filepath in sys.argv[1:]:
        process_file(filepath)
