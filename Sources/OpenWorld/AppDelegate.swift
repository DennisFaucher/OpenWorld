import AppKit
import MetalKit

final class GameView: MTKView {
    var input: Input!
    private var mouseCaptured = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.acceptsMouseMovedEvents = true
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.releaseMouse()
            self?.input.keys.removeAll()
        }
    }

    func captureMouse() {
        guard !mouseCaptured else { return }
        mouseCaptured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
    }

    func releaseMouse() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        input.keys.insert(event.keyCode)
        if event.keyCode == Key.space { input.jumpQueued = true }
        if event.keyCode == Key.esc { releaseMouse() }
    }

    override func keyUp(with event: NSEvent) {
        input.keys.remove(event.keyCode)
    }

    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            input.keys.insert(Key.shift)
        } else {
            input.keys.remove(Key.shift)
        }
    }

    /// The first click captures the cursor; after that the left button is the
    /// spray trigger.
    override func mouseDown(with event: NSEvent) {
        if mouseCaptured { input.spray = true } else { captureMouse() }
    }

    override func mouseUp(with event: NSEvent) { input.spray = false }

    override func mouseMoved(with event: NSEvent) { accumulate(event) }
    override func mouseDragged(with event: NSEvent) { accumulate(event) }

    private func accumulate(_ event: NSEvent) {
        guard mouseCaptured else { return }
        input.mouseDX += Float(event.deltaX)
        input.mouseDY += Float(event.deltaY)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device available") }
        Save.enabled = true
        renderer = Renderer(device: device, save: Save.load())
        renderer.game.onShard = { [weak self] _ in self?.saveProgress() }

        let view = GameView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), device: device)
        view.input = renderer.input
        renderer.configure(view)
        // Silence is an acceptable failure: if the engine cannot start, the game
        // still runs, it just has no sound.
        renderer.audio = Audio()

        window = NSWindow(contentRect: view.frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "OpenWorld \(Version.string)"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        buildMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        renderer?.audio?.stop()
        saveProgress()
    }

    /// Written on every pickup and on the way out: the file is a few hundred
    /// bytes, and losing the crystal you just walked a kilometre for is the one
    /// failure a player would notice.
    private func saveProgress() {
        guard Save.enabled, let renderer else { return }
        Save.write(Save.state(of: renderer.game))
    }

    // MARK: - menu

    /// Mute lives in the menu rather than on a key: the game has no pause, and a
    /// stray keystroke during a jump is not how anyone wants to find silence.
    @objc private func toggleMute(_ item: NSMenuItem) {
        guard let audio = renderer?.audio else { return }
        audio.muted.toggle()
        item.state = audio.muted ? .on : .off
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit OpenWorld", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        let mute = viewMenu.addItem(withTitle: "Mute Sound", action: #selector(toggleMute(_:)), keyEquivalent: "m")
        mute.target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }
}
