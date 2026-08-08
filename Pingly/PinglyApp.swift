//
//  PinglyApp.swift
//  Pingly
//
//  Created by Aditya Rai on 08/08/26.
//

import SwiftUI

@main
struct PinglyApp: App {
    init() {
        BackgroundTaskManager.shared.registerTasks()
        BackgroundAudioSessionManager.shared.configureAudioSession()
    }
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

