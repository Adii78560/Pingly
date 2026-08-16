//
//  BackgroundTaskManager.swift
//  Relayn
//
//  Created by Senior iOS Developer on 09/08/26.
//

import Foundation
import BackgroundTasks
import UIKit
import os


/// Configures iOS BGTaskScheduler background refresh and peer sync jobs.
final class BackgroundTaskManager {
    
    static let shared = BackgroundTaskManager()
    
    static let refreshTaskID = "com.RaiEnterprise.Relyvo.refresh"
    static let processingTaskID = "com.RaiEnterprise.Relyvo.pttsync"
    
    static let legacyRefreshTaskID = "com.RaiEnterprise.RadioFy.refresh"
    static let legacyProcessingTaskID = "com.RaiEnterprise.RadioFy.pttsync"
    
    private init() {}
    
    /// Registers handlers for iOS BGTaskScheduler. Call in app launch.
    func registerTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskManager.refreshTaskID, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            self.handleAppRefresh(task: appRefreshTask)
        }
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskManager.processingTaskID, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self.handleProcessingTask(task: processingTask)
        }
        
        // Legacy identifiers
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskManager.legacyRefreshTaskID, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            self.handleAppRefresh(task: appRefreshTask)
        }
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskManager.legacyProcessingTaskID, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self.handleProcessingTask(task: processingTask)
        }
        
        AppLogger.multipeer.info("BGTaskScheduler tasks registered successfully")
    }
    
    /// Schedules periodic background refresh request.
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskManager.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min minimum window
        
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.multipeer.info("Scheduled BGAppRefreshTask successfully")
        } catch {
            AppLogger.multipeer.error("Could not schedule background app refresh: \(error.localizedDescription)")
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        
        task.expirationHandler = {
            // App background refresh window expired
        }
        
        task.setTaskCompleted(success: true)
    }
    
    private func handleProcessingTask(task: BGProcessingTask) {
        task.expirationHandler = {
            AudioStreamEngine.shared.stopCapture()
        }
        
        // Execute background peer discovery maintenance & flush pending store-and-forward mesh queue
        MultipeerService.shared.flushPendingStoreAndForwardQueue()
        task.setTaskCompleted(success: true)
    }

}
