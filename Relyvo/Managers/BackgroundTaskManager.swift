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
        
        let refreshSuccess = BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskManager.refreshTaskID, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            self.handleAppRefresh(task: appRefreshTask)
        }
        
        let processingSuccess = BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundTaskManager.processingTaskID, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self.handleProcessingTask(task: processingTask)
        }
    }
    
    /// Schedules periodic background refresh request.
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskManager.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min minimum window
        
        
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
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
