import Cocoa
import InputMethodKit

// Create the IMK server — this must happen before NSApplication.run()
let connectionName = Bundle.main.infoDictionary!["InputMethodConnectionName"] as! String
let bundleID = Bundle.main.bundleIdentifier!

NSLog("[VoiceInputIME] Starting with connection: %@, bundle: %@", connectionName, bundleID)

let server = IMKServer(name: connectionName, bundleIdentifier: bundleID)

// Request speech recognition permission early
import Speech
SFSpeechRecognizer.requestAuthorization { status in
    NSLog("[VoiceInputIME] Speech auth status: %d", status.rawValue)
}

NSLog("[VoiceInputIME] IMKServer created, running NSApplication...")
NSApplication.shared.run()
