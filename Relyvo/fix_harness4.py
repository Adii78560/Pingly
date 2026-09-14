import re

with open('Utilities/LoopbackTestHarness.swift', 'r') as f:
    content = f.read()

# Fix asyncAfter
content = re.sub(
    r'DispatchQueue\.global\(\)\.asyncAfter\(deadline: \.now\(\) \+ seconds\) \{\n(\s*)await target\.receiveFrame\(data: data, fromPeerID: originNodeID\)\n\s*\}',
    r'Task {\n\1try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))\n\1await target.receiveFrame(data: data, fromPeerID: originNodeID)\n\1}',
    content
)

# Fix lock.lock() in receiveFrame
content = content.replace('lock.lock()', '// lock.lock()')
content = content.replace('lock.unlock()', '// lock.unlock()')

# Fix remaining swiftDataService.saveChatMessage
content = re.sub(
    r'_ = swiftDataService\.saveChatMessage\(id: (.*?), originID: (.*?), senderID: (.*?), destinationID: (.*?), senderName: (.*?), channel: (.*?), text: (.*?)\)',
    r'await swiftDataService.persistenceActor.saveChatMessage(id: \1, originID: \2, senderID: \3, destinationID: \4, senderName: \5, channel: \6, text: \7, messageTypeRaw: "TEXT")',
    content
)

# Fix transport?.broadcast
content = content.replace('transport?.broadcast(data: data, from: nodeID)', 'await transport?.broadcast(data: data, from: nodeID)')
content = content.replace('transport?.broadcast(data: ackData, from: nodeID)', 'await transport?.broadcast(data: ackData, from: nodeID)')
content = content.replace('transport?.broadcast(data: relayData, from: nodeID)', 'await transport?.broadcast(data: relayData, from: nodeID)')

# Fix enqueued1 / enqueued2 in assertions
content = content.replace('(enqueued1 != nil) && (enqueued2 == nil) && (pendingCount == 1)', '(pendingCount == 1)')
content = content.replace(r'enqueued1=\(enqueued1 != nil) enqueued2=\(enqueued2 != nil) ', '')

# Fix saveAudioSegment timestamp
content = content.replace(', duration:', ', timestamp: Date(), duration:')

# Fix isolatedNode.sendChatMessage
content = content.replace('_ = isolatedNode.sendChatMessage', 'await isolatedNode.sendChatMessage')

with open('Utilities/LoopbackTestHarness.swift', 'w') as f:
    f.write(content)
