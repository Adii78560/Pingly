# 📡 Pingly — Off-Grid Emergency Mesh & Radio Call System

[![Platform](https://img.shields.io/badge/Platform-iOS%2017.0%2B-blue.svg)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Language-Swift%205.9-orange.svg)](https://swift.org)
[![Framework](https://img.shields.io/badge/Framework-SwiftUI-red.svg)](https://developer.apple.com/xcode/swiftui/)
[![Connectivity](https://img.shields.io/badge/Connectivity-AirDrop%20%7C%20Wi--Fi%20P2P%20%7C%20BLE-green.svg)]()
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

**Pingly** is an infrastructure-independent, peer-to-peer emergency communication system designed to keep people connected when conventional networks fail. By leveraging a hybrid mesh network combining **AirDrop / Multipeer Connectivity**, **Wi-Fi Direct / Local Wi-Fi**, and **Bluetooth Low Energy (BLE)**, Pingly enables nearby devices to drop messages, share distress signals, and broadcast live PTT (Push-To-Talk) radio calls without cellular service, internet connection, or satellite hardware.

---

## 🏔️ Mission & Emergency Scenarios

Pingly is built specifically for critical, life-threatening environments where public telecom infrastructure is unavailable, destroyed, or suppressed:

- **Mountain & Wilderness Expeditions**: Remote hiking, mountaineering, skiing, or search & rescue missions in off-grid terrain.
- **Natural Disasters & Grid Failures**: Earthquakes, hurricanes, tsunamis, floods, or power blackouts that render cell towers non-functional.
- **Conflict & War Zones**: Active combat zones, telecom blackouts, or electronic warfare environments where internet and cellular networks are shut down or monitored.
- **Urban Emergencies**: Subways, basements, stadium crowds, or disaster response ops with congested or damaged cellular networks.

---

## ⚡ Key Features & Technologies

### 1. 📶 Multi-Protocol Peer-to-Peer Signal Mesh
Pingly dynamically scans and connects across multiple local radio frequencies to establish an ad-hoc local network:
- **AirDrop & Multipeer Connectivity Framework**: Auto-discovers nearby Apple devices over combined Wi-Fi and Bluetooth radios, establishing instant high-bandwidth peer channels.
- **Wi-Fi Direct / Local Wi-Fi Signal Dropping**: Utilizes local Wi-Fi packets for longer-range, high-speed message payload delivery.
- **Bluetooth Low Energy (BLE) Mesh & Beaconing**: Operates in low-power mode to broadcast beacon pings, detect nearby survivors, and relay distress signals through intermediate node hops.

### 2. 📨 Emergency Message Dropping
- **Proximity Ping & Signal Drop**: Broadcast text messages, GPS coordinates, and medical/status alerts to any user within radio range.
- **Multi-Hop Store-and-Forward Mesh**: Messages pass seamlessly from device to device. Even if the target user is out of range, intermediate devices relay the message until it reaches the destination or a connected node.

### 3. 🎙️ Off-Grid PTT Radio Calls
- **Infrastructure-Free Push-To-Talk (PTT)**: Stream real-time compressed audio directly over P2P Wi-Fi/Bluetooth channels.
- **Emergency Channel Broadcasts**: Walkie-talkie style radio calls allowing team leads, rescue teams, or nearby survivors to coordinate in real time.

### 4. 🛰️ Offline Location & SOS Beaconing
- **Proximity Radar**: Visual indicator showing nearby Pingly nodes based on Bluetooth/Wi-Fi RSSI signal strength.
- **One-Tap Emergency SOS**: Continuously broadcasts a distress beacon containing critical status information (e.g., injuries, team size, last known coordinates).

---

## 🛠️ How It Works

```
                        [ Survivor Device A ]
                                 │
                 (BLE Beacon / Wi-Fi Direct Signal)
                                 │
                                 ▼
                        [ Relay Node B ]
                                 │
             (AirDrop / Multipeer Connectivity Mesh)
                                 │
                                 ▼
    ┌────────────────────────────┴────────────────────────────┐
    │                                                         │
    ▼                                                         ▼
[ Search & Rescue Team ]                          [ Off-Grid Radio Call ]
(Message Delivered)                              (Live Voice Broadcast)
```

1. **Discovery**: Pingly runs continuous background and foreground BLE and Wi-Fi advertising using Apple's `MultipeerConnectivity` and `CoreBluetooth`.
2. **Handshake**: Nearby devices automatically verify proximity keys and form an encrypted peer cluster.
3. **Data & Voice Transfer**:
   - **Messages**: Encoded as lightweight JSON payloads and distributed across active peers.
   - **Radio Calls**: Encoded using Opus / AAC audio codecs via `AVFoundation` and streamed live over `Network.framework` local P2P channels.

---

## 📋 System Requirements

- **iOS Target**: iOS 17.0+
- **Development Tool**: Xcode 15.0+
- **Language**: Swift 5.9+
- **Device Requirements**: iPhone with Bluetooth 5.0+ and Wi-Fi enabled.

---

## 📦 Required Device Permissions

To operate P2P radio calls and signal mesh, the following permissions are configured in `Info.plist`:

```xml
<!-- Bluetooth Scanning & Advertising -->
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Pingly requires Bluetooth to discover nearby devices and relay emergency SOS mesh messages.</string>

<!-- Local Network Access for P2P Wi-Fi -->
<key>NSLocalNetworkUsageDescription</key>
<string>Pingly uses local Wi-Fi to establish direct voice radio calls and high-bandwidth message drops.</string>

<!-- Microphone Access for Radio Calls -->
<key>NSMicrophoneUsageDescription</key>
<string>Pingly requires microphone access for off-grid Push-To-Talk radio voice communication.</string>

<!-- Location for SOS Coordinates -->
<key>NSLocationWhenInUseUsageDescription</key>
<string>Pingly uses location data to attach GPS coordinates to emergency SOS distress pings.</string>
```

---

## 🚀 Getting Started

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/Adii78560/Pingly.git
   cd Pingly
   ```

2. **Open in Xcode**:
   ```bash
   open Pingly.xcodeproj
   ```

3. **Build & Run**:
   - Select your target iOS Device (Physical device recommended for testing P2P Bluetooth/Wi-Fi hardware connectivity).
   - Press `Cmd + R` to run.

---

## 🛡️ License

Distributed under the MIT License. See `LICENSE` for more information.
