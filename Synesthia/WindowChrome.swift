import AppKit
import SwiftUI

/// Strips the host window down to a pane of glass: the visuals run edge to edge
/// with no title bar strip at all, leaving only the traffic lights floating on
/// top. The window title still names the track in Window ▸ / Mission Control.
struct ChromelessWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view isn't in a window yet at make time.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            Self.configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        Self.configure(window)
    }

    private static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        // Hiding the title text is what removes the opaque strip; the traffic
        // lights stay, floating over the canvas.
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // The title bar is gone, so dragging has to work from the canvas.
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        // Below this the bottom chrome can't lay out without clipping.
        window.contentMinSize = minimumContentSize
    }
}
