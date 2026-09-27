import AppKit
import IOKit.hidsystem
import SwiftUI

@MainActor
private final class BalanceViewModel: ObservableObject {
  @Published private(set) var currentValue = 50.0
  @Published private(set) var message: String?
  @Published private(set) var hasError = false

  init() {
    do {
      currentValue = try AudioBalance.readPercentage()
    } catch {
      show(error)
    }
  }

  func setPreset(_ percentage: Double) {
    set(percentage)
  }

  func setEditing(_ isEditing: Bool) {
    self.isEditing = isEditing
  }

  private func set(_ percentage: Double) {
    do {
      try AudioBalance.setPercentage(percentage)
      currentValue = try AudioBalance.readPercentage()
      message = nil
      hasError = false
    } catch {
      show(error)
    }
  }

  private func show(_ error: Error) {
    message = error.localizedDescription
    hasError = true
  }

  private var pollTask: Task<Void, Never>?
  private var isEditing = false

  /// Poll the device balance so the summary tracks external changes
  /// (e.g. System Settings > Sound).
  func startPolling() {
    guard pollTask == nil else { return }
    pollTask = Task.detached {
      while !Task.isCancelled {
        let value = try? AudioBalance.readPercentage()
        await MainActor.run {
          if let value, !self.isEditing {
            self.currentValue = value
          }
        }
        try? await Task.sleep(for: .milliseconds(150))
      }
    }
  }

}

@MainActor
private final class SoundSourceViewModel: ObservableObject {
  @Published private(set) var status: String?
  @Published private(set) var hasError = false
  @Published private(set) var isRunning = false
  @Published private(set) var isSoundSourceOn: Bool

  private var statusPollTask: Task<Void, Never>?
  private var statusClearTask: Task<Void, Never>?

  init() {
    isSoundSourceOn = Self.soundSourceIsRunning
  }

  func startStatusPolling() {
    guard statusPollTask == nil else { return }
    statusPollTask = Task {
      while !Task.isCancelled {
        isSoundSourceOn = Self.soundSourceIsRunning
        try? await Task.sleep(for: .milliseconds(150))
      }
    }
  }

  func run(_ decision: Decision) {
    guard !isRunning else { return }
    isRunning = true
    status = nil
    hasError = false
    // Cancel any pending clear from a previous run so it can't
    // blank out this run's messages.
    statusClearTask?.cancel()

    Task.detached {
      do {
        try SoundSourceWorkflow.run(decision: decision) { text in
          Task { @MainActor in
            self.status = text
          }
        }
        await MainActor.run {
          self.isRunning = false
          // Variant 1: schedule the clear only now that the workflow
          // has finished, so intermediate progress messages are never
          // cleared mid-run (even the long volume ramps).
          self.scheduleStatusClear()
        }
      } catch {
        await MainActor.run {
          self.isRunning = false
          self.status = error.localizedDescription
          self.hasError = true
          // Variant 2: no clear scheduled — error messages stay on
          // screen until the next run.
        }
      }
    }
  }

  /// Blank the status line 3 seconds after it was scheduled.
  /// Only called on successful completion; never for errors.
  private func scheduleStatusClear() {
    // Variant 2 (defensive): never auto-clear an error message.
    guard !hasError else { return }

    statusClearTask?.cancel()
    statusClearTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.status = nil
    }
  }

  private static var soundSourceIsRunning: Bool {
    !NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.rogueamoeba.soundsource"
    ).isEmpty
  }
}

@MainActor
private final class VolumeViewModel: ObservableObject {
  @Published private(set) var volume: Int?
  @Published private(set) var errorMessage: String?
  private var pollTask: Task<Void, Never>?
  private var isEditing = false

  func setVolume(_ percentage: Double) {
    let value = Int(percentage.rounded())
    volume = value
    if SystemVolume.setPercentage(value) {
      errorMessage = nil
      return
    }
    do {
      try SoundSourceWorkflow.setOutputVolume(value)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func setEditing(_ isEditing: Bool) {
    self.isEditing = isEditing
  }

  /// Poll the output volume so the display tracks the workflow's volume
  /// ramps as well as external changes (system volume keys, other apps).
  func start() {
    guard pollTask == nil else { return }
    pollTask = Task.detached {
      while !Task.isCancelled {
        let value =
          SystemVolume.readPercentage() ?? (try? SoundSourceWorkflow.currentOutputVolume())
        await MainActor.run {
          if let value, !self.isEditing {
            self.volume = value
          }
        }
        try? await Task.sleep(for: .milliseconds(150))
      }
    }
  }
}

private struct BrightnessDisplay: Identifiable {
  let id: CGDirectDisplayID
  let name: String
  var percentage: Double
  var readErrorMessage: String?
  var writeErrorMessage: String?
  var isEditing = false

  var isSupported: Bool {
    readErrorMessage == nil && writeErrorMessage == nil
  }

  var isBuiltIn: Bool {
    CGDisplayIsBuiltin(id) != 0
  }

  var errorMessage: String? {
    writeErrorMessage ?? readErrorMessage
  }
}

@MainActor
private final class BrightnessViewModel: ObservableObject {
  @Published private(set) var displays: [BrightnessDisplay] = []
  @Published private(set) var statusMessage: String?

  private let service = DisplayBrightnessService()
  private var pollTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?

  func start() {
    guard pollTask == nil else { return }

    reloadDisplays()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.reloadDisplays()
      }
    }

    pollTask = Task {
      while !Task.isCancelled {
        refreshBrightness()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil

    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
      self.screenObserver = nil
    }
  }

  func setPercentage(_ percentage: Double, for displayID: CGDirectDisplayID) {
    guard
      percentage.isFinite,
      let index = displays.firstIndex(where: { $0.id == displayID })
    else {
      return
    }

    let clampedPercentage = min(max(percentage, 0), 100)
    displays[index].percentage = clampedPercentage

    do {
      try service.setPercentage(clampedPercentage, for: displayID)
      displays[index].writeErrorMessage = nil
    } catch {
      displays[index].writeErrorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func adjustTopDisplay(by percentagePoints: Double) -> Bool {
    guard let display = displays.first, display.isSupported else {
      return false
    }

    setPercentage(display.percentage + percentagePoints, for: display.id)
    return true
  }

  func setEditing(_ isEditing: Bool, for displayID: CGDirectDisplayID) {
    guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
      return
    }

    displays[index].isEditing = isEditing
    if !isEditing {
      refreshBrightness(for: displayID)
    }
  }

  private func reloadDisplays() {
    let descriptors = service.activeDisplays()
    guard !descriptors.isEmpty else {
      displays = []
      statusMessage =
        service.availabilityError?.localizedDescription
        ?? "No active displays were detected."
      return
    }

    let existingDisplays = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
    let nameCounts = Dictionary(grouping: descriptors, by: \.name).mapValues(\.count)
    var nameIndexes: [String: Int] = [:]

    displays = descriptors.map { descriptor in
      let nameIndex = nameIndexes[descriptor.name, default: 0] + 1
      nameIndexes[descriptor.name] = nameIndex

      var name = descriptor.name
      if nameCounts[descriptor.name, default: 0] > 1 {
        name = "\(descriptor.name) \(nameIndex)"
      }
      let existingDisplay = existingDisplays[descriptor.id]

      do {
        let percentage = try service.readPercentage(for: descriptor.id)
        return BrightnessDisplay(
          id: descriptor.id,
          name: name,
          percentage: percentage,
          readErrorMessage: nil,
          writeErrorMessage: nil,
          isEditing: existingDisplay?.isEditing ?? false
        )
      } catch {
        return BrightnessDisplay(
          id: descriptor.id,
          name: name,
          percentage: existingDisplay?.percentage ?? 0,
          readErrorMessage: error.localizedDescription,
          writeErrorMessage: nil,
          isEditing: existingDisplay?.isEditing ?? false
        )
      }
    }
    statusMessage = nil
  }

  private func refreshBrightness() {
    let displayIDs = displays.filter { !$0.isEditing }.map(\.id)
    for displayID in displayIDs {
      refreshBrightness(for: displayID)
    }
  }

  private func refreshBrightness(for displayID: CGDirectDisplayID) {
    guard let index = displays.firstIndex(where: { $0.id == displayID }) else {
      return
    }

    do {
      displays[index].percentage = try service.readPercentage(for: displayID)
      displays[index].readErrorMessage = nil
    } catch {
      displays[index].readErrorMessage = error.localizedDescription
    }
  }
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}

private struct SolidButtonStyle: ButtonStyle {
  let color: Color
  var borderColor: Color? = nil
  let isHotkeyPressed: Bool
  let isHovered: Bool

  private func overlayColor(isActive: Bool) -> Color {
    if isActive {
      return Color.black.opacity(0.03)
    }
    if isHovered {
      return Color.white.opacity(0.10)
    }
    return Color.clear
  }

  func makeBody(configuration: Configuration) -> some View {
    let isActive = configuration.isPressed || isHotkeyPressed

    configuration.label
      .background {
        RoundedRectangle(cornerRadius: 7)
          .fill(color)
          .overlay {
            RoundedRectangle(cornerRadius: 7)
              .fill(overlayColor(isActive: isActive))
          }
          .overlay {
            if let borderColor {
              RoundedRectangle(cornerRadius: 7)
                .stroke(borderColor, lineWidth: 1)
            }
          }
      }
      .scaleEffect(isActive ? 0.97 : 1)
      .animation(.easeOut(duration: 0.08), value: isActive)
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}

private struct ActionButton: View {
  let title: String
  let key: KeyEquivalent
  let color: Color
  var caption: String? = nil
  var width: CGFloat = 96
  var borderColor: Color? = nil
  let isHotkeyPressed: Bool
  let isEnabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .font(.headline)
        Text(caption ?? String(key.character).uppercased())
          .font(.caption.monospaced())
          .foregroundStyle(.white.opacity(0.75))
      }
      .foregroundStyle(.white)
      .frame(width: width)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(
      SolidButtonStyle(
        color: color,
        borderColor: borderColor,
        isHotkeyPressed: isHotkeyPressed,
        isHovered: isHovered
      )
    )
    .keyboardShortcut(key, modifiers: [])
    .focusable(false)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    .onHover { isHovered = $0 }
  }
}

private struct BrightnessPresetButton: View {
  let title: String
  let displayName: String
  let color: Color
  let isEnabled: Bool
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
    .accessibilityLabel("Set \(displayName) brightness to \(title)")
    .buttonStyle(
      SolidButtonStyle(
        color: color,
        isHotkeyPressed: false,
        isHovered: isHovered
      )
    )
    .focusable(false)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    .onHover { isHovered = $0 }
  }
}

private struct SoundSourceStatus: View {
  let isOn: Bool

  var body: some View {
    Text(isOn ? "On" : "Off")
      .foregroundStyle(isOn ? Color(hex: 0x30FF20) : Color(hex: 0xFF102A))
      .fontWeight(.semibold)
      .font(.system(size: 14))
  }
}

private struct BalanceSummary: View {
  let rightPercentage: Int

  private var leftPercentage: Int {
    100 - rightPercentage
  }

  private func color(for percentage: Int) -> Color {
    if percentage == 50 {
      return Color(nsColor: .labelColor).opacity(0.9)
    }
    if percentage > 50 {
      return Color(hex: 0x30FF20)
    }
    return Color(hex: 0xFF102A)
  }

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 3) {
        Text("L:")
          .foregroundStyle(.secondary)
        Text("\(leftPercentage)%")
          .foregroundStyle(color(for: leftPercentage))
          .fontWeight(.semibold)
      }
      HStack(spacing: 3) {
        Text("R:")
          .foregroundStyle(.secondary)
        Text("\(rightPercentage)%")
          .foregroundStyle(color(for: rightPercentage))
          .fontWeight(.semibold)
      }
    }
    .font(.system(size: 13))
  }
}

private struct BalanceSlider: View {
  @ObservedObject var model: BalanceViewModel
  let isEnabled: Bool

  private var accentColor: Color {
    Color(red: 0.10, green: 0.30, blue: 0.70)
  }

  /// Drags that land within this many points of center snap to 50, so the
  /// thumb pulls into center on the way in and has to be dragged clear of
  /// the zone to leave it.
  private static let centerSnapRadius = 4.0

  private var value: Binding<Double> {
    Binding(
      get: { model.currentValue },
      set: { newValue in
        let isNearCenter = abs(newValue - 50) <= Self.centerSnapRadius
        let target = isNearCenter ? 50 : newValue
        if target == 50, model.currentValue.rounded() != 50 {
          NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        model.setPreset(target)
      }
    )
  }

  private var slider: some View {
    Slider(
      value: value,
      in: 0...100,
      step: 1,
      neutralValue: 50,
      label: { EmptyView() },
      tick: { value in
        if value == 50 {
          return SliderTick(value)
        }
        return nil
      },
      onEditingChanged: model.setEditing
    )
  }

  var body: some View {
    HStack(spacing: 8) {
      Text("L")
        .font(.callout.bold())
        .frame(width: 12, alignment: .leading)

      slider
        .tint(accentColor)
        .accessibilityLabel("Custom balance")
        .accessibilityValue("\(Int(model.currentValue.rounded())) percent right")
        .frame(height: 22)

      Text("R")
        .font(.callout.bold())
        .frame(width: 12, alignment: .trailing)
    }
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
  }
}

private struct VolumeSlider: View {
  @ObservedObject var model: VolumeViewModel
  let isEnabled: Bool

  private var accentColor: Color {
    Color(red: 0.1, green: 0.6, blue: 0.0)
  }

  private var accentColorPercent: Color {
    Color(red: 0.2, green: 0.9, blue: 0)
  }

  private var percentageText: String {
    guard let volume = model.volume else { return "–" }
    return "\(volume)%"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text("System Volume")
          .font(.headline)
        Spacer()
        Text(percentageText)
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(accentColorPercent)
      }

      HStack(spacing: 8) {
        Image(systemName: "speaker.fill")
          .foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { Double(model.volume ?? 0) },
            set: { model.setVolume($0) }
          ),
          in: 0...100,
          step: 1,
          onEditingChanged: model.setEditing
        )
        .tint(accentColor)
        .disabled(!isEnabled || model.volume == nil)
        .accessibilityLabel("System volume")
        .accessibilityValue(percentageText)
        Image(systemName: "speaker.wave.3.fill")
          .foregroundStyle(.secondary)
      }
      .opacity(isEnabled ? 1 : 0.45)

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(Color.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct BrightnessControlRow: View {
  let display: BrightnessDisplay
  let accentColor: Color
  @ObservedObject var model: BrightnessViewModel

  private var percentageText: String {
    "\(Int(display.percentage.rounded()))%"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(display.name)
          .font(.headline)
        Spacer()
        Text(percentageText)
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(accentColor)
      }

      HStack(spacing: 8) {
        Image(systemName: "sun.min")
          .foregroundStyle(.secondary)
        Slider(
          value: Binding(
            get: { display.percentage },
            set: { model.setPercentage($0, for: display.id) }
          ),
          in: 0...100,
          step: 1,
          onEditingChanged: { model.setEditing($0, for: display.id) }
        )
        .tint(accentColor)
        .disabled(!display.isSupported)
        .accessibilityLabel("\(display.name) brightness")
        .accessibilityValue(percentageText)
        Image(systemName: "sun.max.fill")
          .foregroundStyle(.secondary)
      }

      if let errorMessage = display.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(Color.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private final class FocusClearingView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    DispatchQueue.main.async { [weak window] in
      window?.level = .floating
      window?.makeFirstResponder(nil)
    }
  }
}

private struct InitialFocusClearer: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    FocusClearingView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ContentView: View {
  @StateObject private var balanceModel = BalanceViewModel()
  @StateObject private var soundSourceModel = SoundSourceViewModel()
  @StateObject private var volumeModel = VolumeViewModel()
  @StateObject private var brightnessModel = BrightnessViewModel()
  @State private var keyMonitor: Any?
  @State private var activeHotkey: Character?

  private func brightnessColor(for index: Int) -> Color {
    if index == 0 {
      return Color(hex: 0xFFA000)
    }
    return Color(hex: 0xFF6D00)
  }

  private func brightnessTopPadding(for index: Int) -> CGFloat {
    if index == 0 {
      return 0
    }
    return 12
  }

  private static let brightnessPresetColors: [Color] = [
    Color(hex: 0x0F0103),
    Color(hex: 0x31010B),
    Color(hex: 0x61010D),
    Color(hex: 0x810010),
    Color(hex: 0xA10012),
  ]

  private func brightnessPresets(for display: BrightnessDisplay) -> [Int] {
    display.isBuiltIn ? [0, 5, 50, 75, 100] : [0, 40, 60, 80, 100]
  }

  private func brightnessPresetButtons(for display: BrightnessDisplay) -> some View {
    HStack(spacing: 8) {
      ForEach(Array(brightnessPresets(for: display).enumerated()), id: \.offset) {
        index, value in
        BrightnessPresetButton(
          title: "\(value)",
          displayName: display.name,
          color: Self.brightnessPresetColors[index],
          isEnabled: display.isSupported
        ) {
          brightnessModel.setPercentage(Double(value), for: display.id)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 12)
    // .padding(.bottom, 8)
  }

  private func triggerBalanceHotkey(_ key: Character, percentage: Double) {
    guard activeHotkey == nil else {
      return
    }

    activeHotkey = key
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      activeHotkey = nil
      balanceModel.setPreset(percentage)
    }
  }

  private func triggerSoundSourceHotkey(_ key: Character, decision: Decision) {
    guard activeHotkey == nil else {
      return
    }

    activeHotkey = key
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      activeHotkey = nil
      soundSourceModel.run(decision)
    }
  }

  private func brightnessAdjustment(for event: NSEvent) -> Double? {
    let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
    guard event.modifierFlags.intersection(reservedModifiers).isEmpty else {
      return nil
    }

    if event.type == .keyDown {
      switch event.specialKey {
      case .f1:
        return -5
      case .f2:
        return 5
      default:
        return nil
      }
    }

    guard event.type == .systemDefined, event.subtype.rawValue == 8 else {
      return nil
    }

    let keyState = (event.data1 & 0x0000_FF00) >> 8
    guard keyState == 0xA else {
      return nil
    }

    let mediaKeyCode = (event.data1 & 0xFFFF_0000) >> 16
    switch mediaKeyCode {
    case Int(NX_KEYTYPE_BRIGHTNESS_DOWN):
      return -5
    case Int(NX_KEYTYPE_BRIGHTNESS_UP):
      return 5
    default:
      return nil
    }
  }

  private func handleHotkey(_ event: NSEvent) -> NSEvent? {
    if let adjustment = brightnessAdjustment(for: event),
      brightnessModel.adjustTopDisplay(by: adjustment)
    {
      return nil
    }

    guard event.type == .keyDown else {
      return event
    }

    let reservedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
    guard event.modifierFlags.intersection(reservedModifiers).isEmpty else {
      return event
    }

    let key = event.charactersIgnoringModifiers?.lowercased()

    // Quit stays available even while a SoundSource workflow is running.
    if event.keyCode == 53 || key == "q" {
      NSApp.terminate(nil)
      return nil
    }

    guard !soundSourceModel.isRunning else {
      return event
    }

    switch key {
    case "l":
      triggerBalanceHotkey("l", percentage: 0)
    case "c":
      triggerBalanceHotkey("c", percentage: 50)
    case "r":
      triggerBalanceHotkey("r", percentage: 100)
    case "k":
      triggerSoundSourceHotkey("k", decision: .kill)
    case "s":
      triggerSoundSourceHotkey("s", decision: .restart)
    case "t":
      triggerSoundSourceHotkey("t", decision: .toggle)
    default:
      return event
    }

    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text("SoundSource")
            .font(.title2.bold())
          SoundSourceStatus(isOn: soundSourceModel.isSoundSourceOn)
        }

        HStack(spacing: 0) {
          ActionButton(
            title: "Kill", key: "k", color: Color(hex: 0x115500),
            isHotkeyPressed: activeHotkey == "k",
            isEnabled: !soundSourceModel.isRunning
          ) {
            soundSourceModel.run(.kill)
          }
          Spacer()
          ActionButton(
            title: "reStart", key: "s", color: Color(hex: 0x6B006B),
            isHotkeyPressed: activeHotkey == "s",
            isEnabled: !soundSourceModel.isRunning
          ) {
            soundSourceModel.run(.restart)
          }
          Spacer()
          ActionButton(
            title: "Toggle", key: "t", color: Color(hex: 0x003388),
            isHotkeyPressed: activeHotkey == "t",
            isEnabled: !soundSourceModel.isRunning
          ) {
            soundSourceModel.run(.toggle)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        // .padding(.top, 14)

        Text(soundSourceModel.status ?? " ")
          .font(.system(size: 11))
          .italic()
          .foregroundStyle(soundSourceModel.hasError ? Color.red : Color.white.opacity(0.65))
          .padding(.top, 6)
      }

      Divider()
        .padding(.bottom, 8)
				// .padding(.top, 4)

      VStack(alignment: .leading, spacing: 0) {
        Text("Audio")
          .font(.title2.bold())

        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Custom Balance")
              .font(.headline)
            Spacer()
            BalanceSummary(
              rightPercentage: Int(balanceModel.currentValue.rounded())
            )
          }

          BalanceSlider(
            model: balanceModel,
            isEnabled: !soundSourceModel.isRunning
          )

					if let message = balanceModel.message {
						Text(message)
							.font(.system(size: 11))
							.italic()
							.foregroundStyle(balanceModel.hasError ? Color.red : Color.white.opacity(0.65))
							.fixedSize(horizontal: false, vertical: true)
							.padding(.top, 2)
					}
        }
        .padding(.top, 16)

        HStack(spacing: 8) {
          ActionButton(
            title: "Left", key: "l", color: Color(hex: 0x440088),
            isHotkeyPressed: activeHotkey == "l",
            isEnabled: !soundSourceModel.isRunning
          ) {
            balanceModel.setPreset(0)
          }
          ActionButton(
            title: "Center", key: "c", color: Color(hex: 0x660011),
            isHotkeyPressed: activeHotkey == "c",
            isEnabled: !soundSourceModel.isRunning
          ) {
            balanceModel.setPreset(50)
          }
          ActionButton(
            title: "Right", key: "r", color: Color(hex: 0x005853),
            isHotkeyPressed: activeHotkey == "r",
            isEnabled: !soundSourceModel.isRunning
          ) {
            balanceModel.setPreset(100)
          }
        }
        .frame(maxWidth: .infinity)
				.padding(.top, 16)

        VolumeSlider(
          model: volumeModel,
          isEnabled: !soundSourceModel.isRunning
        )
        .padding(.top, 20)
      }
			.padding(.bottom, 8)

      Divider()
        .padding(.vertical, 8)

      VStack(alignment: .leading, spacing: 16) {
        Text("Display Brightness")
          .font(.title2.bold())

        if brightnessModel.displays.isEmpty {
          Text(brightnessModel.statusMessage ?? "Detecting displays…")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(brightnessModel.displays.enumerated()), id: \.element.id) {
            index, display in
            VStack(alignment: .leading, spacing: 12) {
              BrightnessControlRow(
                display: display,
                accentColor: brightnessColor(for: index),
                model: brightnessModel
              )

              brightnessPresetButtons(for: display)
            }
            .padding(.top, brightnessTopPadding(for: index))
          }
        }
      }
			.padding(.bottom, 8)

      Divider()
        .padding(.vertical, 8)

      HStack {
        Spacer()
        ActionButton(
          title: "Quit", key: "q", color: Color(hex: 0x19191C),
          caption: "Q / esc", width: 160, borderColor: Color(hex: 0x353538),
          isHotkeyPressed: false,
          isEnabled: true
        ) {
          NSApp.terminate(nil)
        }
        Spacer()
      }
			.padding(.top, 8)
    }
    .padding(22)
    .frame(width: 350)
    .background {
      Color(hex: 0x111111)
      InitialFocusClearer()
    }
    .preferredColorScheme(.dark)
    .onAppear {
      soundSourceModel.startStatusPolling()
      volumeModel.start()
      balanceModel.startPolling()
      brightnessModel.start()
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .systemDefined]) { event in
        handleHotkey(event)
      }
    }
    .onDisappear {
      brightnessModel.stop()
      if let keyMonitor {
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
      }
    }
  }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard
      let iconURL = Bundle.main.url(forResource: "SuperAV", withExtension: "icns"),
      let icon = NSImage(contentsOf: iconURL)
    else {
      return
    }

    NSApp.applicationIconImage = icon
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}

@main
private struct SuperAVApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}
