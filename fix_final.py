import re

with open('Relyvo/Services/PersistenceActor.swift', 'r') as f:
    content = f.read()

# Fix PersistenceActor
content = content.replace('messageType: .text,', 'messageType: .chat,')
# Let's completely replace the init in performPersistenceReadWriteDiagnosticTest to ensure correct order
content = re.sub(
    r'let testMessage = SDChatMessage\([\s\S]*?isDelivered: true\n\s*\)',
    r'let testMessage = SDChatMessage(\n            id: testID,\n            originID: "DIAGNOSTIC",\n            senderID: "DIAGNOSTIC",\n            destinationID: "DIAGNOSTIC",\n            senderName: "DiagnosticSystem",\n            channel: "DIAGNOSTIC_CHANNEL",\n            text: testText,\n            timestamp: Date(),\n            isSynced: true,\n            isDelivered: true,\n            messageType: .chat\n        )',
    content
)

with open('Relyvo/Services/PersistenceActor.swift', 'w') as f:
    f.write(content)

with open('Relyvo/Services/MultipeerService.swift', 'r') as f:
    content = f.read()

# Fix status: .sending
content = content.replace('status: .sending)', 'statusRaw: "SENDING")')

# Wrap enqueuePendingMessage with Task {} if it's in a non-async context
content = re.sub(
    r'(await SwiftDataService\.shared\.persistenceActor\.enqueuePendingMessage\()',
    r'Task { \1',
    content
)
content = re.sub(
    r'(ttl: 5\n\s*)\)',
    r'\1) }',
    content
)

# Fix the saveChatMessage at line 1340. We will just globally replace missing senderID and messageTypeRaw.
# Let's find any saveChatMessage that lacks messageTypeRaw
content = re.sub(
    r'await SwiftDataService\.shared\.persistenceActor\.saveChatMessage\(\s*id: (.*?),\s*originID: (.*?),\s*destinationID: (.*?),\s*senderName: (.*?),\s*channel: (.*?),\s*text: (.*?)\s*\)',
    r'await SwiftDataService.shared.persistenceActor.saveChatMessage(\n                    id: \1,\n                    originID: \2,\n                    senderID: \2,\n                    destinationID: \3,\n                    senderName: \4,\n                    channel: \5,\n                    text: \6,\n                    messageTypeRaw: "TEXT"\n                )',
    content
)

with open('Relyvo/Services/MultipeerService.swift', 'w') as f:
    f.write(content)

