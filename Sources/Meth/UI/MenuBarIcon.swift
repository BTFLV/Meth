import AppKit

public enum MenuBarIcon {
    public static func image(isActive: Bool, isClosedLid: Bool) -> NSImage {
        let symbolName: String
        if !isActive {
            symbolName = "cup.and.saucer"
        } else if isClosedLid {
            symbolName = "bolt.shield.fill"
        } else {
            symbolName = "cup.and.saucer.fill"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Meth") {
            image.isTemplate = true
            return image
        }

        // Fallback procedural vector icon if systemSymbolName is unavailable
        return createFallbackImage(isActive: isActive, isClosedLid: isClosedLid)
    }

    private static func createFallbackImage(isActive: Bool, isClosedLid: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            if isActive {
                NSColor.labelColor.setFill()
                path.fill()
                if isClosedLid {
                    let dot = NSBezierPath(ovalIn: NSRect(x: 7, y: 7, width: 4, height: 4))
                    NSColor.windowBackgroundColor.setFill()
                    dot.fill()
                }
            } else {
                NSColor.labelColor.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

