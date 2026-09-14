import re

with open('/Users/adityarai/Desktop/Pingly/Relyvo/Services/SwiftDataService.swift', 'r') as f:
    lines = f.readlines()

methods_to_remove = [
    "func saveVoiceTranscript(",
    "func markTranscriptsAsDelivered(",
    "func saveAudioSegment(",
    "func saveVoiceMessage(",
    "func markVoiceMessageAsPlayed(",
    "func markVoiceMessagesAsDelivered(",
    "func updateVoiceMessageFilePath(",
    "func saveChatMessage(",
    "func saveMessage(",
    "func savePendingMessage(",
    "func enqueuePendingMessage(",
    "func enqueueRelayMessage(",
    "func resetFailedPendingMessages(",
    "func updatePendingMessageStatus(",
    "func markPendingMessageAsACKed(",
    "func updateLocationShareSession("
]

new_lines = []
skip = False
brace_count = 0
in_method = False

for line in lines:
    if not in_method:
        should_skip = False
        for m in methods_to_remove:
            if m in line:
                in_method = True
                should_skip = True
                # count braces on this line
                brace_count += line.count('{') - line.count('}')
                break
        
        if not should_skip:
            new_lines.append(line)
    else:
        # We are inside a method to remove
        brace_count += line.count('{') - line.count('}')
        if brace_count <= 0:
            # We reached the end of the method body
            in_method = False
            brace_count = 0

with open('/Users/adityarai/Desktop/Pingly/Relyvo/Services/SwiftDataService.swift', 'w') as f:
    f.writelines(new_lines)
