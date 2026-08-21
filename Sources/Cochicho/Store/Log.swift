import Foundation
import os

enum Log {
    static let app = Logger(subsystem: "com.mateus.cochicho", category: "app")
    static let audio = Logger(subsystem: "com.mateus.cochicho", category: "audio")
    static let speech = Logger(subsystem: "com.mateus.cochicho", category: "speech")
    static let hotkey = Logger(subsystem: "com.mateus.cochicho", category: "hotkey")
    static let inject = Logger(subsystem: "com.mateus.cochicho", category: "inject")
}
