#if os(macOS)
import AppKit
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
#else
import Foundation
print("Point & Tell requires macOS 11 or later. The core library tests can run on Linux.")
#endif
