import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "com.mateus.ekonami", category: "app")
    static let audio = Logger(subsystem: "com.mateus.ekonami", category: "audio")
    static let speech = Logger(subsystem: "com.mateus.ekonami", category: "speech")
    static let hotkey = Logger(subsystem: "com.mateus.ekonami", category: "hotkey")
    static let inject = Logger(subsystem: "com.mateus.ekonami", category: "inject")
}
