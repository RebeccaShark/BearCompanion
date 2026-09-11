import AppKit
import CoreGraphics
import ImageIO

// Only aggregate keyboard idle time and foreground app identity are observed.
enum Mode: String, CaseIterable {
    case automatic = "自动", idle = "待机", typing = "打字", reading = "阅读", phone = "手机"
}
enum Outfit: String, CaseIterable { case automatic = "随时间换装", day = "白天形象", night = "夜间睡帽" }
enum Reaction: String, CaseIterable { case scratch = "挠挠头", clap = "开心鼓掌", startle = "吓一跳" }
func chooseMode(manual: Mode, bundle: String?, keyboardAllowed: Bool, seconds: Double) -> Mode {
    if manual != .automatic { return manual }
    if bundle == "com.tencent.xinWeChat" { return .phone }
    if bundle == "org.zotero.zotero" { return .reading }
    return keyboardAllowed && seconds.isFinite && seconds >= 0 && seconds < 1.5 ? .typing : .idle
}
func isNight(hour: Int, outfit: Outfit) -> Bool {
    switch outfit { case .day: return false; case .night: return true; case .automatic: return hour >= 22 || hour < 7 }
}
func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.era, .year, .month, .day], from: date)
    return "\(c.era ?? 1)-\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
}
func needsWake(date: Date, last: String?, calendar: Calendar = .current) -> Bool { last != dayKey(date, calendar: calendar) }
func isTap(distance: Double, duration: Double) -> Bool { distance < 5 && duration >= 0 && duration <= 0.45 }
func clipKey(_ mode: Mode, night: Bool) -> String {
    let key: String
    switch mode { case .typing: key = "typing"; case .reading: key = "reading"; case .phone: key = "phone"; default: key = "idle" }
    return night ? "night-" + key : key
}
func reactionKey(_ reaction: Reaction, night: Bool) -> String {
    let key: String
    switch reaction { case .scratch: key = "scratch"; case .clap: key = "clap"; case .startle: key = "startle" }
    return night ? "night-" + key : key
}
func timings(_ key: String) -> [Double] {
    switch key {
    case "walk", "night-walk": return Array(repeating: 0.11, count: 8)
    case "idle": return [0.28,0.11,0.11,0.14,0.14,0.14,0.14,0.32]
    case "typing": return [0.12,0.12,0.12,0.12,0.12,0.12,0.12,0.22]
    case "reading": return Array(repeating: 0.15, count: 7) + [0.28]
    case "wake": return [0.6,0.35,0.35,0.4,0.4,0.35,0.3,0.5]
    case "scratch", "night-scratch": return [0.15,0.15,0.2,0.16,0.16,0.16,0.18,0.3]
    case "clap", "night-clap": return [0.15,0.15,0.17,0.15,0.17,0.15,0.18,0.3]
    case "startle", "night-startle": return [0.16,0.12,0.10,0.16,0.12,0.12,0.16,0.3]
    case "night-idle": return [0.4,0.3,0.3,0.4,0.4,0.3,0.3,0.5]
    default: return Array(repeating: 0.15, count: 7) + [0.28]
    }
}
struct Playback {
    var key = ""
    var started = 0.0
    mutating func select(_ newKey: String, now: Double) { if key != newKey { key = newKey; started = now } }
    func index(now: Double) -> Int {
        let times = timings(key), total = times.reduce(0, +)
        var elapsed = max(0, now - started).truncatingRemainder(dividingBy: total)
        for (i, duration) in times.enumerated() { if elapsed < duration { return i }; elapsed -= duration }
        return times.count - 1
    }
}
struct DragMotion {
    var active = false
    var facesLeft = false
    var lastMotion = 0.0
    var horizontalTravel = 0.0
    mutating func update(dx: Double, dy: Double, now: Double) {
        if !active { horizontalTravel = 0 }
        active = true
        if hypot(dx, dy) > 0.25 { lastMotion = now }
        // Ignore subpixel reversals; vertical drags retain the previous facing.
        if dx * horizontalTravel < 0 { horizontalTravel = 0 }
        horizontalTravel += dx
        if abs(horizontalTravel) >= 2 { facesLeft = horizontalTravel < 0; horizontalTravel = 0 }
    }
    func moving(now: Double) -> Bool { active && now - lastMotion < 0.18 }
    mutating func end() { active = false; horizontalTravel = 0 }
}
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class PetView: NSView {
    var bitmap: NSBitmapImageRep?
    var frameImage: CGImage? { didSet { bitmap = frameImage.map { NSBitmapImageRep(cgImage: $0) }; needsDisplay = true } }
    var onTap: (() -> Void)?
    var onDrag: ((Double, Double) -> Void)?
    var onDragEnd: (() -> Void)?
    var lastDragPoint = NSPoint.zero
    var mirrored = false { didSet { if oldValue != mirrored { needsDisplay = true } } }
    var pressPoint: NSPoint?
    var pressOrigin = NSPoint.zero
    var pressTime = 0.0
    var maxDistance = 0.0
    override var mouseDownCanMoveWindow: Bool { false }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p), let bitmap = bitmap else { return }
        let x = min(bitmap.pixelsWide - 1, max(0, Int(p.x / bounds.width * Double(bitmap.pixelsWide))))
        let y = min(bitmap.pixelsHigh - 1, max(0, bitmap.pixelsHigh - 1 - Int(p.y / bounds.height * Double(bitmap.pixelsHigh))))
        guard (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 else { return }
        pressPoint = NSEvent.mouseLocation; pressOrigin = window?.frame.origin ?? .zero
        lastDragPoint = pressPoint!
        pressTime = event.timestamp; maxDistance = 0
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint else { return }
        let p = NSEvent.mouseLocation, dx = p.x - start.x, dy = p.y - start.y
        maxDistance = max(maxDistance, hypot(dx, dy))
        if maxDistance >= 5 {
            window?.setFrameOrigin(NSPoint(x: pressOrigin.x + dx, y: pressOrigin.y + dy))
            onDrag?(p.x - lastDragPoint.x, p.y - lastDragPoint.y)
            lastDragPoint = p
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard let start = pressPoint else { return }
        let p = NSEvent.mouseLocation
        maxDistance = max(maxDistance, hypot(p.x - start.x, p.y - start.y))
        pressPoint = nil
        if maxDistance >= 5 { onDragEnd?() }
        else if isTap(distance: maxDistance, duration: event.timestamp - pressTime) { onTap?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image = frameImage, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        if mirrored { ctx.translateBy(x: bounds.width, y: 0); ctx.scaleBy(x: -1, y: 1) }
        ctx.interpolationQuality = .high; ctx.draw(image, in: bounds)
        ctx.restoreGState()
    }
}
final class Companion: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: PetPanel!
    let pet = PetView(frame: NSRect(x: 0, y: 0, width: 192, height: 208))
    var status: NSStatusItem!
    var timer: Timer?
    var manual: Mode = .automatic
    var outfit = Outfit(rawValue: UserDefaults.standard.string(forKey: "outfit") ?? "") ?? .automatic
    var images: [String: [CGImage]] = [:]
    var playback = Playback()
    var displayedFrame = ""
    var oneShot: (key: String, until: Double)?
    var lastReaction: Reaction?
    var dragMotion = DragMotion()
    var notes: [String] = []
    var night: Bool { isNight(hour: Calendar.current.component(.hour, from: Date()), outfit: outfit) }
    var root: URL {
        let beside = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Assets")
        if FileManager.default.fileExists(atPath: beside.path) { return beside }
        return Bundle.main.resourceURL!.appendingPathComponent("Assets")
    }
    func loadImage(_ url: URL, width: Int, height: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil), img.width == width, img.height == height else { return nil }
        return img
    }
    @objc func reloadAssets() {
        images.removeAll(); notes.removeAll()
        for key in ["walk", "night-walk", "idle", "typing", "reading", "phone", "scratch", "clap", "startle", "wake", "night-idle", "night-typing", "night-reading", "night-phone", "night-scratch", "night-clap", "night-startle"] {
            if let strip = loadImage(root.appendingPathComponent(key + ".png"), width: 1536, height: 208) {
                images[key] = (0..<8).compactMap { strip.cropping(to: CGRect(x: $0 * 192, y: 0, width: 192, height: 208)) }
            } else { notes.append("\(key) 素材缺失／无效") }
        }
        playback = Playback(); displayedFrame = ""; oneShot = nil; tick()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Keep a single desktop companion, even if launched from another copy.
        let identifier = Bundle.main.bundleIdentifier ?? "local.bearcompanion.app"
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        if let first = peers.min(by: { $0.processIdentifier < $1.processIdentifier }), first.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.bearcompanion.app.show"), object: identifier, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPet), name: Notification.Name("local.bearcompanion.app.show"), object: identifier)
        panel = PetPanel(contentRect: pet.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false; panel.contentView = pet
        pet.onTap = { [weak self] in self?.react() }
        pet.onDrag = { [weak self] dx, dy in
            guard let self = self else { return }
            self.oneShot = nil
            self.dragMotion.update(dx: dx, dy: dy, now: ProcessInfo.processInfo.systemUptime)
            self.tick()
        }
        pet.onDragEnd = { [weak self] in self?.dragMotion.end(); self?.tick() }
        pet.setAccessibilityElement(true); pet.setAccessibilityRole(.button)
        pet.setAccessibilityLabel("自嘲熊"); pet.setAccessibilityHelp("轻点互动，按住拖动可移动")
        recenter()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); status.button?.title = "熊伴"
        let menu = NSMenu(); menu.delegate = self; status.menu = menu
        let context = NSMenu(); context.delegate = self; pet.menu = context
        reloadAssets()
        let date = Date()
        if needsWake(date: date, last: UserDefaults.standard.string(forKey: "lastWakeDay")), playOnce("wake") {
            UserDefaults.standard.set(dayKey(date), forKey: "lastWakeDay")
        }
        panel.orderFrontRegardless()
        timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    @discardableResult func playOnce(_ key: String) -> Bool {
        guard let frames = images[key], frames.count == timings(key).count else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        oneShot = (key, now + timings(key).reduce(0, +)); playback = Playback(key: key, started: now)
        tick(); return true
    }
    func react(_ requested: Reaction? = nil) {
        guard oneShot == nil else { return }
        let candidates = Reaction.allCases.filter { $0 != lastReaction }
        let selected = requested ?? candidates.randomElement() ?? .scratch
        if playOnce(reactionKey(selected, night: night)) { lastReaction = selected }
    }
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let shot = oneShot, now >= shot.until { oneShot = nil }
        let allowed = CGPreflightListenEventAccess()
        let seconds = allowed ? CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) : .infinity
        let mode = chooseMode(manual: manual, bundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, keyboardAllowed: allowed, seconds: seconds)
        let desired = dragMotion.active ? (night ? "night-walk" : "walk") : (oneShot?.key ?? clipKey(mode, night: night))
        pet.mirrored = dragMotion.active && dragMotion.facesLeft
        let key = images[desired]?.isEmpty == false ? desired : (images[clipKey(.idle, night: night)]?.isEmpty == false ? clipKey(.idle, night: night) : "idle")
        playback.select(key, now: now)
        guard let frames = images[key], !frames.isEmpty else { pet.frameImage = nil; return }
        let index = dragMotion.active && !dragMotion.moving(now: now) ? min(7, frames.count - 1) : min(playback.index(now: now), frames.count - 1)
        let tag = "\(key):\(index)"
        if displayedFrame != tag {
            displayedFrame = tag; pet.frameImage = frames[index]
            let names = ["walk":"走路", "idle":"待机", "typing":"打字", "reading":"阅读", "phone":"手机", "scratch":"挠挠头", "clap":"开心鼓掌", "startle":"吓一跳", "wake":"起床"]
            let base = key.replacingOccurrences(of: "night-", with: "")
            let title = key == "night-idle" ? "抱枕困困" : (names[base] ?? base)
            pet.setAccessibilityLabel("自嘲熊 · " + (key.hasPrefix("night-") ? "睡帽 · " : "") + title)
        }
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let visibility = menu.addItem(withTitle: panel?.isVisible == true ? "隐藏小熊" : "显示小熊", action: #selector(toggleVisibility), keyEquivalent: "")
        visibility.target = self
        let exit = menu.addItem(withTitle: "退出熊伴", action: #selector(quit), keyEquivalent: "")
        exit.target = self
        menu.addItem(.separator())
        for mode in Mode.allCases {
            let item = menu.addItem(withTitle: mode.rawValue, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue; item.state = mode == manual ? .on : .off
        }
        menu.addItem(.separator())
        for choice in Outfit.allCases {
            let item = menu.addItem(withTitle: choice.rawValue, action: #selector(selectOutfit(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = choice.rawValue; item.state = choice == outfit ? .on : .off
        }
        menu.addItem(withTitle: "夜间时段：22:00–07:00（本地时间）", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for reaction in Reaction.allCases {
            let item = menu.addItem(withTitle: reaction.rawValue, action: #selector(previewReaction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = reaction.rawValue
        }
        let wake = menu.addItem(withTitle: "重播起床", action: #selector(previewWake), keyEquivalent: ""); wake.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: CGPreflightListenEventAccess() ? "输入监控：已授权" : "输入监控：未授权，自动打字已停用", action: nil, keyEquivalent: "")
        for note in notes { menu.addItem(withTitle: note, action: nil, keyEquivalent: "") }
        for (title, action) in [("重新加载素材", #selector(reloadAssets)), ("将宠物移回主屏", #selector(recenter))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
    }
    @objc func selectMode(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let mode = Mode(rawValue: raw) { manual = mode; oneShot = nil; tick() }
    }
    @objc func selectOutfit(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let choice = Outfit(rawValue: raw) { outfit = choice; UserDefaults.standard.set(choice.rawValue, forKey: "outfit"); tick() }
    }
    @objc func previewReaction(_ item: NSMenuItem) { if let raw = item.representedObject as? String, let reaction = Reaction(rawValue: raw) { oneShot = nil; react(reaction) } }
    @objc func previewWake() { playOnce("wake") }
    @objc func recenter() { if let screen = NSScreen.main { panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 220, y: screen.visibleFrame.minY + 24)) } }
    @objc func toggleVisibility() {
        guard let panel = panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { showPet() }
    }
    @objc func showPet() { panel?.orderFrontRegardless(); tick() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showPet(); return true }
    @objc func quit() { NSApp.terminate(nil) }
}
if CommandLine.arguments.contains("--self-test") {
    func check(_ expected: Mode, _ manual: Mode = .automatic, _ bundle: String? = nil, _ allowed: Bool = true, _ seconds: Double = 0) {
        precondition(chooseMode(manual: manual, bundle: bundle, keyboardAllowed: allowed, seconds: seconds) == expected)
    }
    check(.phone, .automatic, "com.tencent.xinWeChat"); check(.reading, .automatic, "org.zotero.zotero")
    check(.typing); check(.idle, .automatic, nil, false); check(.idle, .automatic, nil, true, 1.5)
    check(.idle, .automatic, nil, true, .infinity); check(.idle, .automatic, nil, true, -1)
    check(.typing, .typing, "com.tencent.xinWeChat", false); check(.reading, .automatic, "org.zotero.zotero", false)
    for (hour, expected) in [(0,true),(6,true),(7,false),(21,false),(22,true),(23,true)] { precondition(isNight(hour: hour, outfit: .automatic) == expected) }
    precondition(!isNight(hour: 23, outfit: .day) && isNight(hour: 12, outfit: .night))
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let d = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 23, minute: 59))!
    precondition(needsWake(date: d, last: nil, calendar: calendar))
    precondition(!needsWake(date: d, last: dayKey(d, calendar: calendar), calendar: calendar))
    precondition(needsWake(date: d.addingTimeInterval(120), last: dayKey(d, calendar: calendar), calendar: calendar))
    precondition(isTap(distance: 0, duration: 0.1) && !isTap(distance: 5, duration: 0.1) && !isTap(distance: 0, duration: 0.46))
    var drag = DragMotion()
    drag.update(dx: -6, dy: 0, now: 10)
    precondition(drag.active && drag.facesLeft && drag.moving(now: 10.1))
    drag.update(dx: 0, dy: 9, now: 10.1)
    precondition(drag.facesLeft && !drag.moving(now: 10.4))
    drag.update(dx: 0.4, dy: 0, now: 10.5)
    precondition(drag.facesLeft) // tiny hand jitter cannot reverse the bear
    drag.update(dx: 4, dy: 0, now: 10.6)
    precondition(!drag.facesLeft && drag.moving(now: 10.6))
    drag.end(); precondition(!drag.active && !drag.moving(now: 10.6))
    var p = Playback(); p.select("clap", now: 10); precondition(p.index(now: 10) == 0 && p.index(now: 10.16) == 1)
    p.select("clap", now: 10.2); precondition(p.started == 10)
    p.select("night-idle", now: 11); precondition(p.started == 11 && p.index(now: 11) == 0)
    for m in [Mode.idle,.typing,.reading,.phone] { precondition(clipKey(m, night: true).hasPrefix("night-")) }
    let c = Companion(); c.reloadAssets()
    let required = ["walk","night-walk","idle","typing","reading","phone","scratch","clap","startle","wake","night-idle","night-typing","night-reading","night-phone","night-scratch","night-clap","night-startle"]
    if CommandLine.arguments.contains("--require-assets") { for key in required { precondition(c.images[key]?.count == timings(key).count, "Missing or invalid clip: \(key)") } }
    if c.images["clap"] != nil {
        precondition(c.playOnce("clap")); let active = c.oneShot!.key; c.react(.startle); precondition(c.oneShot!.key == active)
        c.oneShot = (active, ProcessInfo.processInfo.systemUptime - 1); c.tick(); precondition(c.oneShot == nil)
    }
    if c.images["walk"] != nil && c.images["night-walk"] != nil {
        c.manual = .idle; c.outfit = .day
        c.dragMotion.update(dx: -8, dy: 0, now: ProcessInfo.processInfo.systemUptime)
        c.tick(); precondition(c.playback.key == "walk" && c.pet.mirrored)
        c.outfit = .night; c.tick(); precondition(c.playback.key == "night-walk")
        c.dragMotion.end(); c.tick()
        precondition(c.playback.key == "night-idle" && !c.pet.mirrored)
    }
    print("PASS: app priority, permission gate, night boundaries, outfit override, daily wake date, tap/drag threshold, drag directions/pause/release, playback, one-shot priority and asset counts")
} else {
    let app = NSApplication.shared; let delegate = Companion(); app.delegate = delegate; app.run()
}
