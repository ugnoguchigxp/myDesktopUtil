import AppKit
import DeskCore
import QuartzCore

@MainActor
final class AlarmController {
  private var panel: NSPanel?
  private var sound: NSSound?
  private var dismissHandler: (() -> Void)?

  var isVisible: Bool {
    panel != nil
  }

  func show(_ alert: Alert, onDismiss: @escaping () -> Void) {
    dismiss()

    guard let screen = Self.currentScreen() else {
      onDismiss()
      return
    }
    dismissHandler = onDismiss
    let visibleFrame = screen.visibleFrame
    let cardSize = NSSize(
      width: max(1, min(300, visibleFrame.width - 40)),
      height: max(1, min(200, visibleFrame.height - 40))
    )
    let cardFrame = NSRect(
      x: visibleFrame.midX - cardSize.width / 2,
      y: visibleFrame.maxY - cardSize.height - 24,
      width: cardSize.width,
      height: cardSize.height
    )
    let panel = AlarmPanel(
      contentRect: cardFrame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false,
      screen: screen
    )
    panel.minSize = cardSize
    panel.maxSize = cardSize
    panel.level = .screenSaver
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .transient,
      .ignoresCycle,
    ]

    let rootView = AlarmRootView(frame: NSRect(origin: .zero, size: cardSize))
    rootView.onDismiss = { [weak self] in
      self?.dismiss()
    }
    panel.contentView = rootView

    let bell = BellView()
    bell.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(bell)

    let title = NSTextField(labelWithString: alert.title)
    title.translatesAutoresizingMaskIntoConstraints = false
    title.alignment = .center
    title.textColor = .white
    title.font = .systemFont(ofSize: 17, weight: .bold)
    title.maximumNumberOfLines = 1
    title.lineBreakMode = .byTruncatingTail
    title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    rootView.addSubview(title)

    let body = NSTextField(labelWithString: alert.body)
    body.translatesAutoresizingMaskIntoConstraints = false
    body.alignment = .center
    body.textColor = NSColor.white.withAlphaComponent(0.9)
    body.font = .systemFont(ofSize: 12, weight: .medium)
    body.maximumNumberOfLines = 2
    body.lineBreakMode = .byTruncatingTail
    body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    rootView.addSubview(body)

    let dismissLabel = NSTextField(labelWithString: "クリックして停止")
    dismissLabel.translatesAutoresizingMaskIntoConstraints = false
    dismissLabel.alignment = .center
    dismissLabel.textColor = NSColor.white.withAlphaComponent(0.72)
    dismissLabel.font = .systemFont(ofSize: 10, weight: .regular)
    rootView.addSubview(dismissLabel)

    NSLayoutConstraint.activate([
      bell.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
      bell.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 18),
      bell.widthAnchor.constraint(equalToConstant: 48),
      bell.heightAnchor.constraint(equalToConstant: 48),
      title.topAnchor.constraint(equalTo: bell.bottomAnchor, constant: 10),
      title.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
      title.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
      body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
      body.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
      body.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
      dismissLabel.bottomAnchor.constraint(
        equalTo: rootView.safeAreaLayoutGuide.bottomAnchor,
        constant: -11
      ),
      dismissLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
    ])

    self.panel = panel
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    if #available(macOS 14.0, *) {
      NSApp.activate()
    } else {
      NSApp.activate(ignoringOtherApps: true)
    }
    bell.startAnimating()

    if let tone = ToneSoundFactory.makeSound() {
      tone.loops = true
      tone.volume = 0.8
      tone.play()
      sound = tone
    }
  }

  func dismiss() {
    guard panel != nil else {
      return
    }
    sound?.stop()
    sound = nil
    panel?.contentView?.layer?.removeAllAnimations()
    panel?.orderOut(nil)
    panel?.close()
    panel = nil
    let handler = dismissHandler
    dismissHandler = nil
    handler?()
  }

  private static func currentScreen() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
  }
}

@MainActor
private final class AlarmRootView: NSView {
  var onDismiss: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor =
      NSColor(
        calibratedRed: 0.13,
        green: 0.012,
        blue: 0.018,
        alpha: 0.97
      ).cgColor
    layer?.cornerRadius = 18
    layer?.borderWidth = 1.5
    layer?.borderColor =
      NSColor(calibratedRed: 0.7, green: 0.08, blue: 0.1, alpha: 1).cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    self
  }

  override func mouseDown(with event: NSEvent) {
    onDismiss?()
  }
}

@MainActor
private final class AlarmPanel: NSPanel {
  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}

@MainActor
private final class BellView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
  }

  convenience init() {
    self.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor(calibratedRed: 1, green: 0.78, blue: 0.12, alpha: 1).setFill()
    NSColor(calibratedWhite: 1, alpha: 0.95).setStroke()

    let width = bounds.width
    let height = bounds.height
    let bellPath = NSBezierPath()
    bellPath.move(to: CGPoint(x: width * 0.27, y: height * 0.29))
    bellPath.curve(
      to: CGPoint(x: width * 0.38, y: height * 0.72),
      controlPoint1: CGPoint(x: width * 0.32, y: height * 0.4),
      controlPoint2: CGPoint(x: width * 0.28, y: height * 0.65)
    )
    bellPath.curve(
      to: CGPoint(x: width * 0.62, y: height * 0.72),
      controlPoint1: CGPoint(x: width * 0.43, y: height * 0.83),
      controlPoint2: CGPoint(x: width * 0.57, y: height * 0.83)
    )
    bellPath.curve(
      to: CGPoint(x: width * 0.73, y: height * 0.29),
      controlPoint1: CGPoint(x: width * 0.72, y: height * 0.65),
      controlPoint2: CGPoint(x: width * 0.68, y: height * 0.4)
    )
    bellPath.close()
    bellPath.lineWidth = 5
    bellPath.fill()
    bellPath.stroke()

    let clapper = NSBezierPath(
      ovalIn: CGRect(
        x: width * 0.43,
        y: height * 0.17,
        width: width * 0.14,
        height: height * 0.14
      )
    )
    clapper.fill()
  }

  func startAnimating() {
    let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    animation.values = [-0.22, 0, 0.22]
    animation.keyTimes = [0, 0.5, 1]
    animation.duration = 0.3
    animation.autoreverses = true
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = true
    layer?.add(animation, forKey: "bell-swing")
  }
}

private enum ToneSoundFactory {
  static func makeSound() -> NSSound? {
    let sampleRate = 22_050
    let duration = 0.22
    let sampleCount = Int(Double(sampleRate) * duration)
    var pcm = Data(capacity: sampleCount * 2)

    for index in 0..<sampleCount {
      let time = Double(index) / Double(sampleRate)
      let envelope = max(0, 1 - (time / duration))
      let sample = sin(2 * .pi * 880 * time) * envelope * 0.45
      var value = Int16(sample * Double(Int16.max)).littleEndian
      withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
    }

    var wave = Data()
    wave.append(contentsOf: "RIFF".utf8)
    append(UInt32(36 + pcm.count), to: &wave)
    wave.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16), to: &wave)
    append(UInt16(1), to: &wave)
    append(UInt16(1), to: &wave)
    append(UInt32(sampleRate), to: &wave)
    append(UInt32(sampleRate * 2), to: &wave)
    append(UInt16(2), to: &wave)
    append(UInt16(16), to: &wave)
    wave.append(contentsOf: "data".utf8)
    append(UInt32(pcm.count), to: &wave)
    wave.append(pcm)
    return NSSound(data: wave)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }
}
