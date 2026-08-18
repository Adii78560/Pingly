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
    
    private init() {}
    
    /// Registers handlers for iOS BGTaskScheduler. Call in app launch.
    func registerTasks() {
        AppLogger.multipeer.info("[BackgroundTasks] Registration started")
        
        AppLogger.multipeer.info("[BackgroundTasks] Registering task identifier = \(BackgroundTaskManager.refreshTaskID)")
        let refreshSuccess = BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskManager.refreshTaskID, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            self.handleAppRefresh(task: appRefreshTask)
        }
        AppLogger.multipeer.info("[BackgroundTasks] Registration succeeded = \(refreshSuccess)")
        
        AppLogger.multipeer.info("[BackgroundTasks] Registering task identifier = \(BackgroundTaskManager.processingTaskID)")
        let processingSuccess = BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskManager.processingTaskID, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self.handleProcessingTask(task: processingTask)
        }
        AppLogger.multipeer.info("[BackgroundTasks] Registration succeeded = \(processingSuccess)")
    }
    
    /// Schedules periodic background refresh request.
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskManager.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min minimum window
        
        AppLogger.multipeer.info("[BackgroundTasks] Scheduling task identifier = \(request.identifier)")
        
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.multipeer.info("[BackgroundTasks] Scheduled BGAppRefreshTask successfully")
        } catch {
            AppLogger.multipeer.error("[BackgroundTasks][ERROR] Could not schedule background app refresh: \(error.localizedDescription)")
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
