import AppKit

/// The menu bar glyph: the same Erlenmeyer-flask-and-crystal mark as the app icon, drawn
/// as a template image so macOS tints it correctly in light mode, dark mode, and while the
/// menu is highlighted.
///
/// It is drawn from vector paths in code rather than scaled down from the full-colour
/// artwork in `Assets/logo`: a 16-18pt glyph needs its own weights (a much heavier glass
/// outline, no gradients, no specular highlights) to stay legible, and drawing it here
/// keeps it resolution-independent on every display without shipping bitmap variants.
public enum MenuBarIcon {
    /// Menu bar glyphs are laid out in an 18x18 point box by convention.
    private static let canvas = NSSize(width: 18, height: 18)
    private static let outlineWidth: CGFloat = 1.4

    public static func image(isActive: Bool, isClosedLid: Bool) -> NSImage {
        let image = NSImage(size: canvas, flipped: true) { _ in
            let flask = flaskPath()
            let lip = lipPath()

            if isActive && isClosedLid {
                // Closed-Lid Mode is the state with real consequences (the Mac will not
                // sleep even with the lid shut), so it gets the boldest, most immediately
                // distinguishable form: a solid flask.
                NSColor.black.setFill()
                flask.fill()
                lip.fill()
            } else {
                NSColor.black.setStroke()
                flask.lineWidth = outlineWidth
                flask.lineJoinStyle = .round
                flask.stroke()

                NSColor.black.setFill()
                lip.fill()

                if isActive {
                    crystalPath().fill()
                }
            }
            return true
        }

        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(isActive: isActive, isClosedLid: isClosedLid)
        return image
    }

    private static func accessibilityDescription(isActive: Bool, isClosedLid: Bool) -> String {
        switch (isActive, isClosedLid) {
        case (false, _): return "Meth — inactive"
        case (true, false): return "Meth — keeping your Mac awake"
        case (true, true): return "Meth — keeping your Mac awake with the lid closed"
        }
    }

    /// Centreline of the glass outline: neck, flared body, rounded base.
    private static func flaskPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 7.3, y: 2.6))
        path.line(to: NSPoint(x: 7.3, y: 6.9))
        path.line(to: NSPoint(x: 3.75, y: 14.65))
        path.curve(
            to: NSPoint(x: 4.85, y: 15.95),
            controlPoint1: NSPoint(x: 3.25, y: 15.7),
            controlPoint2: NSPoint(x: 3.25, y: 15.7)
        )
        path.line(to: NSPoint(x: 13.15, y: 15.95))
        path.curve(
            to: NSPoint(x: 14.25, y: 14.65),
            controlPoint1: NSPoint(x: 14.75, y: 15.7),
            controlPoint2: NSPoint(x: 14.75, y: 15.7)
        )
        path.line(to: NSPoint(x: 10.7, y: 6.9))
        path.line(to: NSPoint(x: 10.7, y: 2.6))
        path.close()
        return path
    }

    private static func lipPath() -> NSBezierPath {
        NSBezierPath(
            roundedRect: NSRect(x: 6.2, y: 1.2, width: 5.6, height: 1.55),
            xRadius: 0.775,
            yRadius: 0.775
        )
    }

    /// The faceted crystal, reduced to its silhouette; facets are invisible at this size.
    private static func crystalPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 9.0, y: 8.7))
        path.line(to: NSPoint(x: 11.6, y: 11.75))
        path.line(to: NSPoint(x: 9.0, y: 14.8))
        path.line(to: NSPoint(x: 6.4, y: 11.75))
        path.close()
        return path
    }
}
