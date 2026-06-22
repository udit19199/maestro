//
//  CurrentTimeTool.swift
//  zoro
//
//  Created by Antigravity on 19/06/26.
//

import Foundation
import FoundationModels

struct CurrentTimeTool: Tool {
    let name = "current_time"
    let description = "Get the current system date, time, and timezone."
    
    @Generable
    struct Arguments {}
    
    func call(arguments: Arguments) async throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.string(from: Date())
    }
}
