import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Audible Environment Live Diagnostics"
window.center()
window.isReleasedWhenClosed = false

let connection = NSTextField(labelWithString: "Mac hostname: \(CommandLine.arguments[2])     Viewer code: \(CommandLine.arguments[3])")
connection.isSelectable = true
let live = NSImageView()
live.imageScaling = .scaleProportionallyUpOrDown
live.heightAnchor.constraint(equalToConstant: 250).isActive = true
let liveStatus = NSTextField(labelWithString: "Waiting for glasses frames…")
let frames = NSStackView()
frames.orientation = .horizontal
frames.distribution = .fillEqually
frames.heightAnchor.constraint(equalToConstant: 120).isActive = true
let details = NSTextView()
details.isEditable = false
details.string = "Waiting for the first Gemini request…"
let scroll = NSScrollView()
scroll.hasVerticalScroller = true
scroll.documentView = details
details.autoresizingMask = [.width]
details.frame.size.width = 940
details.textContainer?.widthTracksTextView = true

let stack = NSStackView(views: [connection, NSTextField(labelWithString: "Live glasses view"),
                               liveStatus, live, NSTextField(labelWithString: "Frames sent to Gemini"),
                               frames, scroll])
stack.orientation = .vertical
stack.alignment = .leading
stack.spacing = 8
stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
window.contentView = stack
for view in [live, frames, scroll] {
    view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
}

struct Exchange: Decodable {
    let id: String
    let frames: [Data]
    let prompt: String
    let response: String
}

@MainActor final class CloseHandler: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.stop(nil) }
}
let closeHandler = MainActor.assumeIsolated { CloseHandler() }
window.delegate = closeHandler
var previousPreview: Data?
var previousExchange: Data?
var exchangeID: String?
let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
    MainActor.assumeIsolated {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("preview.jpg")),
           data != previousPreview, let image = NSImage(data: data) {
            previousPreview = data
            live.image = image
            liveStatus.stringValue = "Receiving glasses frames"
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("exchange.json")),
           data != previousExchange, let exchange = try? JSONDecoder().decode(Exchange.self, from: data) {
            previousExchange = data
            if exchange.id != exchangeID {
                for view in frames.arrangedSubviews {
                    frames.removeArrangedSubview(view)
                    view.removeFromSuperview()
                }
                for data in exchange.frames {
                    let view = NSImageView()
                    view.image = NSImage(data: data)
                    view.imageScaling = .scaleProportionallyUpOrDown
                    frames.addArrangedSubview(view)
                }
                exchangeID = exchange.id
            }
            details.string = "PROMPT\n\(exchange.prompt)\n\nGEMINI\n\(exchange.response)"
        }
    }
}
RunLoop.main.add(timer, forMode: .common)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
