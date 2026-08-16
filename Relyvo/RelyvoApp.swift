//
//  RelyvoApp.swift
//  Relyvo
//
//  Created by Senior iOS Developer on 16/08/26.
//

import SwiftUI

@main
struct RelyvoApp: App {
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
