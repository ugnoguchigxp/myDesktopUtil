import AppKit

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

runApplication()
