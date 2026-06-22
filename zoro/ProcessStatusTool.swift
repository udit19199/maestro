//
//  ProcessStatusTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels

struct ProcessStatusTool: Tool {
    let name = "get_process_status"
    let description = "Check the status, running state, and output logs of active background processes."
    
    @Generable
    struct Arguments {
        @Guide(description: "The Task ID of the background process, or empty string to list all active processes.")
        var taskId: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        let activeProcesses = await WorkspaceManager.shared.activeProcesses
        
        if arguments.taskId.isEmpty {
            if activeProcesses.isEmpty {
                return "No background processes currently active."
            }
            var lines = ["Active background processes:"]
            for (id, proc) in activeProcesses {
                let status = (await proc.isRunning) ? "RUNNING" : "TERMINATED"
                lines.append("- [\(id)] (\(status)) Command: \(proc.command)")
            }
            return lines.joined(separator: "\n")
        }
        
        guard let proc = activeProcesses[arguments.taskId] else {
            return "Error: No background process found with Task ID '\(arguments.taskId)'."
        }
        
        let status = (await proc.isRunning) ? "RUNNING" : "TERMINATED"
        let output = await proc.getAvailableOutput()
        
        var response = "Task ID: \(arguments.taskId)\nStatus: \(status)\nCommand: \(proc.command)\n"
        if !output.isEmpty {
            response += "\nNew Output Logs:\n\(output)"
        } else {
            response += "\nNo new logs since last check."
        }
        return response
    }
}
