import re

with open('Utilities/LoopbackTestHarness.swift', 'r') as f:
    content = f.read()

# Fix saveChatMessage
content = re.sub(
    r'_ = swiftDataService\.saveChatMessage\(\s*id: (.*?),\s*originID: (.*?),\s*senderID: (.*?),\s*destinationID: (.*?),\s*senderName: (.*?),\s*channel: (.*?),\s*text: (.*?)\s*\)',
    r'await swiftDataService.persistenceActor.saveChatMessage(id: \1, originID: \2, senderID: \3, destinationID: \4, senderName: \5, channel: \6, text: \7, messageTypeRaw: "TEXT")',
    content
)
content = re.sub(
    r'_ = swiftDataService\.saveChatMessage\(\s*id: (.*?),\s*originID: (.*?),\s*senderID: (.*?),\s*destinationID: (.*?),\s*senderName: (.*?),\s*channel: (.*?),\s*text: (.*?),\s*isDelivered: (.*?)\s*\)',
    r'await swiftDataService.persistenceActor.saveChatMessage(id: \1, originID: \2, senderID: \3, destinationID: \4, senderName: \5, channel: \6, text: \7, isDelivered: \8, messageTypeRaw: "TEXT")',
    content
)

# Fix enqueuePendingMessage
content = re.sub(
    r'_ = swiftDataService\.enqueuePendingMessage\(\s*messageID: (.*?),\s*originID: (.*?),\s*destinationID: (.*?),\s*recipientName: (.*?),\s*senderName: (.*?),\s*text: (.*?),\s*channel: (.*?)\s*\)',
    r'await swiftDataService.persistenceActor.enqueuePendingMessage(messageID: \1, originID: \2, destinationID: \3, recipientName: \4, senderName: \5, text: \6, channel: \7, isSOS: false, priorityRaw: 0, statusRaw: "QUEUED", queueRoleRaw: "ORIGIN", hopsCount: 0, ttl: 5)',
    content
)
content = re.sub(
    r'let enqueued1 = nodeA10\.swiftDataService\.enqueuePendingMessage\(\s*messageID: (.*?),\s*originID: (.*?),\s*destinationID: (.*?),\s*recipientName: (.*?),\s*senderName: (.*?),\s*text: (.*?),\s*channel: (.*?)\s*\)',
    r'await nodeA10.swiftDataService.persistenceActor.enqueuePendingMessage(messageID: \1, originID: \2, destinationID: \3, recipientName: \4, senderName: \5, text: \6, channel: \7, isSOS: false, priorityRaw: 0, statusRaw: "QUEUED", queueRoleRaw: "ORIGIN", hopsCount: 0, ttl: 5)',
    content
)
content = re.sub(
    r'let enqueued2 = nodeA10\.swiftDataService\.enqueuePendingMessage\(\s*messageID: (.*?),\s*originID: (.*?),\s*destinationID: (.*?),\s*recipientName: (.*?),\s*senderName: (.*?),\s*text: (.*?),\s*channel: (.*?)\s*\)',
    r'await nodeA10.swiftDataService.persistenceActor.enqueuePendingMessage(messageID: \1, originID: \2, destinationID: \3, recipientName: \4, senderName: \5, text: \6, channel: \7, isSOS: false, priorityRaw: 0, statusRaw: "QUEUED", queueRoleRaw: "ORIGIN", hopsCount: 0, ttl: 5)',
    content
)

# Fix updatePendingMessageStatus
content = re.sub(
    r'swiftDataService\.updatePendingMessageStatus\(messageID: (.*?), status: \.sending\)',
    r'await swiftDataService.persistenceActor.updatePendingMessageStatus(messageID: \1, statusRaw: "SENDING")',
    content
)
content = re.sub(
    r'swiftDataService\.updatePendingMessageStatus\(messageID: (.*?), status: \.waitingForACK\)',
    r'await swiftDataService.persistenceActor.updatePendingMessageStatus(messageID: \1, statusRaw: "WAITING_FOR_ACK")',
    content
)
content = re.sub(
    r'nodeA8\.swiftDataService\.updatePendingMessageStatus\(messageID: (.*?), status: PendingMessageStatus\.failed, reason: (.*?)\)',
    r'await nodeA8.swiftDataService.persistenceActor.updatePendingMessageStatus(messageID: \1, statusRaw: "FAILED", reason: \2)',
    content
)
content = re.sub(
    r'nodeA9\.swiftDataService\.updatePendingMessageStatus\(messageID: (.*?), status: PendingMessageStatus\.failed\)',
    r'await nodeA9.swiftDataService.persistenceActor.updatePendingMessageStatus(messageID: \1, statusRaw: "FAILED")',
    content
)

# Fix resetFailedPendingMessages
content = re.sub(
    r'nodeA8\.swiftDataService\.resetFailedPendingMessages\(\)',
    r'await nodeA8.swiftDataService.persistenceActor.resetFailedPendingMessages()',
    content
)

# Fix markPendingMessageAsACKed
content = re.sub(
    r'swiftDataService\.markPendingMessageAsACKed\(messageID: (.*?)\)',
    r'await swiftDataService.persistenceActor.markPendingMessageAsACKed(messageID: \1)',
    content
)

# Fix saveAudioSegment
content = re.sub(
    r'let sdSegment = testNode\.swiftDataService\.saveAudioSegment\(',
    r'await testNode.swiftDataService.persistenceActor.saveAudioSegment(',
    content
)


with open('Utilities/LoopbackTestHarness.swift', 'w') as f:
    f.write(content)
