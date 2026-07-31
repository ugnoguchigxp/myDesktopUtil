import AppKit
import Darwin

@MainActor
func runApplication() {
  let application = NSApplication.shared
  application.setActivationPolicy(.accessory)
  let delegate = AppDelegate()
  application.delegate = delegate
  withExtendedLifetime(delegate) {
    application.run()
  }
}

if let exitCode = CommandLineMode.exitCodeIfRequested() {
  exit(exitCode)
}
runApplication()
