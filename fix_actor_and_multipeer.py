import re

with open('Relyvo/Services/PersistenceActor.swift', 'r') as f:
    content = f.read()

# Fix SDChatMessage init in performPersistenceReadWriteDiagnosticTest
content = content.replace('messageTypeRaw: "TEXT",', 'messageType: .text,')

with open('Relyvo/Services/PersistenceActor.swift', 'w') as f:
    f.write(content)

with open('Relyvo/Services/MultipeerService.swift', 'r') as f:
    content = f.read()

# Fix updatePendingMessageStatus
content = content.replace('status: .failed,', 'statusRaw: "FAILED",')

# Fix saveChatMessage missing senderID, messageTypeRaw in MultipeerService:1330
# It's probably `_ = await SwiftDataService.shared.persistenceActor.saveChatMessage(id: ...)`
# Let's write a targeted regex for saveChatMessage
content = re.sub(
    r'await SwiftDataService\.shared\.persistenceActor\.saveChatMessage\(\s*id: (.*?),\s*originID: (.*?),\s*destinationID: (.*?),\s*senderName: (.*?),\s*channel: (.*?),\s*text: (.*?)\s*\)',
    r'await SwiftDataService.shared.persistenceActor.saveChatMessage(\n                id: \1,\n                originID: \2,\n                senderID: \2,\n                destinationID: \3,\n                senderName: \4,\n                channel: \5,\n                text: \6,\n                messageTypeRaw: "TEXT"\n            )',
    content
)

# Fix enqueuePendingMessage
content = re.sub(
    r'await SwiftDataService\.shared\.persistenceActor\.enqueuePendingMessage\(\s*(.*?),\s*status: \.pending,\s*queueRole: \.origin\s*\)',
    r'await SwiftDataService.shared.persistenceActor.enqueuePendingMessage(\n                messageID: \1.id,\n                originID: \1.originID,\n                destinationID: \1.destinationID,\n                recipientName: \1.destinationID,\n                senderName: \1.senderName,\n                text: \1.text,\n                channel: \1.destinationID,\n                isSOS: \1.isSOS,\n                priorityRaw: 0,\n                statusRaw: "PENDING",\n                queueRoleRaw: "ORIGIN",\n                hopsCount: \1.hopsCount,\n                ttl: 5\n            )',
    content
)

# Fix DispatchQueue.main.asyncAfter with await inside (Line 1070)
# "cannot pass function of type '@concurrent () async -> Void' to parameter expecting synchronous function type"
# We don't know the exact lines, let's find them manually after.

with open('Relyvo/Services/MultipeerService.swift', 'w') as f:
    f.write(content)

