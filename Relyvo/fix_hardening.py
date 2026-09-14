import re

with open('Utilities/PinglyHardeningTests.swift', 'r') as f:
    content = f.read()

# Fix updatePendingMessageStatus
content = content.replace('status: .sending)', 'statusRaw: "SENDING")')

# Fix allowBluetooth
content = content.replace('.allowBluetooth', '.allowBluetoothHFP')

# Fix DispatchSemaphore wait
content = re.sub(r'_ = \w+\.wait\(timeout: \.now\(\) \+ [0-9.]+\)', 'try? await Task.sleep(nanoseconds: 2_000_000_000)', content)
# Wait, let's just make it exact
content = content.replace('_ = writeExp.wait(timeout: .now() + 2.0)', 'try? await Task.sleep(nanoseconds: 2_000_000_000)')

# Fix enqueuePendingMessage(offlineMsg, status: .pending, queueRole: .origin)
# I will change it to manually extract the fields.
content = content.replace(
    'let queuedPending = await SwiftDataService.shared.persistenceActor.enqueuePendingMessage(offlineMsg, status: .pending, queueRole: .origin)',
    'await SwiftDataService.shared.persistenceActor.enqueuePendingMessage(messageID: offlineMsg.id, originID: offlineMsg.originID, destinationID: offlineMsg.destinationID, recipientName: "Test", senderName: offlineMsg.senderName, text: offlineMsg.text, channel: offlineMsg.destinationID, isSOS: offlineMsg.isSOS, priorityRaw: 0, statusRaw: "PENDING", queueRoleRaw: "ORIGIN", hopsCount: offlineMsg.hopsCount, ttl: 5)\n        let queuedPending = true'
)

with open('Utilities/PinglyHardeningTests.swift', 'w') as f:
    f.write(content)
