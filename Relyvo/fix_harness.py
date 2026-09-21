import re

with open('Utilities/LoopbackTestHarness.swift', 'r') as f:
    content = f.read()

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

for m in methods:
    # replace instance calls like node.swiftDataService.method(
    content = re.sub(r'swiftDataService\.' + m + r'\(', r'swiftDataService.persistenceActor.' + m + '(', content)

# But these are in an async test? If they are not awaited, we need to add `await` and `Task {` or just `await` if it's already an async context.
# Since it's a test harness, let's just insert await where needed.
content = content.replace("swiftDataService.persistenceActor", "await swiftDataService.persistenceActor")
content = content.replace("await await", "await")
content = content.replace("await _ = await", "_ = await")
content = content.replace("_ = await swiftDataService", "await swiftDataService")
content = content.replace("let enqueued1 = await swiftDataService", "let enqueued1 = await swiftDataService")
content = content.replace("let enqueued2 = await swiftDataService", "let enqueued2 = await swiftDataService")
content = content.replace("let sdSegment = await testNode.swiftDataService", "let sdSegment = await testNode.swiftDataService")

with open('Utilities/LoopbackTestHarness.swift', 'w') as f:
    f.write(content)
