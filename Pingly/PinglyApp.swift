//
//  RelaynApp.swift
//  Relayn
//
//  Created by Aditya Rai on 08/08/26.
//

import SwiftUI

@main
struct RelaynApp: App {
    init() {
        BackgroundTaskManager.shared.registerTasks()
        BackgroundAudioSessionManager.shared.configureAudioSession()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

}

