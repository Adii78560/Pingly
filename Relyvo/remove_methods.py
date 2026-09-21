import re

def remove_methods(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    methods_to_remove = [
        "performPersistenceReadWriteDiagnosticTest",
        "saveVoiceTranscript",
        "markTranscriptsAsDelivered",
        "saveAudioSegment",
        "saveVoiceMessage",
        "markVoiceMessageAsPlayed",
        "markVoiceMessagesAsDelivered",
        "updateVoiceMessageFilePath",
        "saveChatMessage",
        "saveMessage",
        "savePendingMessage",
        "enqueuePendingMessage",
        "enqueueRelayMessage",
        "resetFailedPendingMessages",
        "updatePendingMessageStatus",
        "markPendingMessageAsACKed",
        "updateLocationShareSession"
    ]

    for m in methods_to_remove:
        pattern = r"func\s+" + m + r"\s*\("
        match = re.search(pattern, content)
        while match:
            start_index = match.start()
            # find the opening brace
            brace_idx = content.find('{', start_index)
            if brace_idx == -1:
                break
            
            # find the closing brace by counting
            brace_count = 1
            end_index = brace_idx + 1
            while end_index < len(content) and brace_count > 0:
                if content[end_index] == '{':
                    brace_count += 1
                elif content[end_index] == '}':
                    brace_count -= 1
                end_index += 1
            
            # remove from start_index to end_index (maybe remove leading attributes like @discardableResult)
            # let's try to remove @discardableResult if it's right before
            # simple backtrace
            prefix = content[:start_index].rstrip()
            if prefix.endswith("@discardableResult"):
                start_index = prefix.rfind("@discardableResult")
                
            content = content[:start_index] + content[end_index:]
            match = re.search(pattern, content)

    with open(filepath, 'w') as f:
        f.write(content)

remove_methods('/Users/adityarai/Desktop/Pingly/Relyvo/Services/SwiftDataService.swift')
