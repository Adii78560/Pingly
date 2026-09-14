import re

with open('/Users/adityarai/Desktop/Pingly/Relyvo/Services/SwiftDataService.swift', 'r') as f:
    content = f.read()

# I will use a simple state machine to delete these methods.
methods_to_remove = [
    "func performPersistenceReadWriteDiagnosticTest",
    "func saveVoiceTranscript",
    "func markTranscriptsAsDelivered",
    "func saveAudioSegment",
    "func saveVoiceMessage",
    "func markVoiceMessageAsPlayed",
    "func markVoiceMessagesAsDelivered",
    "func updateVoiceMessageFilePath",
    "func saveChatMessage",
    "func saveMessage",
    "func savePendingMessage",
    "func enqueuePendingMessage",
    "func enqueueRelayMessage",
    "func resetFailedPendingMessages",
    "func updatePendingMessageStatus",
    "func markPendingMessageAsACKed",
]

lines = content.split('\n')
new_lines = []
skip = False
brace_count = 0

for line in lines:
    if not skip:
        # Check if line starts one of the methods
        should_skip = False
        for m in methods_to_remove:
            if m in line and "{" in line:
                # Basic heuristic for func def
                skip = True
                brace_count = line.count("{") - line.count("}")
                should_skip = True
                break
            elif m in line and not "{" in line:
                # multiline declaration
                # Just assuming it will hit { soon
                skip = True
                brace_count = 0
                should_skip = True
                break
        
        if not should_skip:
            new_lines.append(line)
    else:
        brace_count += line.count("{") - line.count("}")
        if brace_count <= 0:
            skip = False

with open('/Users/adityarai/Desktop/Pingly/Relyvo/Services/SwiftDataService.swift', 'w') as f:
    f.write('\n'.join(new_lines))

