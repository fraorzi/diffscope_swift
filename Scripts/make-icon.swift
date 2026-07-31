#!/usr/bin/env swift
import AppKit

// The application icon, drawn rather than shipped as a binary asset — so it lives in the repository
// as something readable and reviewable, like everything else here.
//
// It is the product's own visual language: two panes, and the diagonal hatch that means "changed".
// No colour carries meaning (DEC-035), which is as true of the icon as of the diff.

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let ink = NSColor(white: 0.10, alpha: 1)
let paper = NSColor(white: 0.97, alpha: 1)

// Rounded square, the shape macOS expects.
let plate = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                         xRadius: size * 0.22, yRadius: size * 0.22)
ink.setFill()
plate.fill()

let inset = size * 0.16
let gap = size * 0.05
let paneWidth = (size - 2 * inset - gap) / 2
let paneHeight = size - 2 * inset

// Left pane: plain lines. Right pane: the same lines with one hatched — a change, in the product's
// own vocabulary.
for (index, x) in [inset, inset + paneWidth + gap].enumerated() {
    let pane = NSBezierPath(roundedRect: NSRect(x: x, y: inset, width: paneWidth, height: paneHeight),
                            xRadius: size * 0.03, yRadius: size * 0.03)
    paper.setFill()
    pane.fill()

    let rows = 7
    let rowHeight = paneHeight / Double(rows + 2)
    for row in 0..<rows {
        let y = inset + paneHeight - rowHeight * Double(row + 1) - rowHeight * 0.5
        let width = paneWidth * [0.72, 0.55, 0.80, 0.48, 0.66, 0.40, 0.58][row]
        let line = NSRect(x: x + paneWidth * 0.10, y: y, width: width, height: rowHeight * 0.42)

        if index == 1 && row == 3 {
            // The changed line, hatched. Same shape on both panes; only the texture differs.
            ink.withAlphaComponent(0.20).setFill()
            NSBezierPath(rect: NSRect(x: x + paneWidth * 0.10, y: y - rowHeight * 0.2,
                                      width: paneWidth * 0.80, height: rowHeight * 0.82)).fill()
            ink.setStroke()
            let hatch = NSBezierPath()
            hatch.lineWidth = size * 0.006
            var offset = -rowHeight
            while offset < paneWidth * 0.80 {
                hatch.move(to: NSPoint(x: x + paneWidth * 0.10 + offset, y: y - rowHeight * 0.2))
                hatch.line(to: NSPoint(x: x + paneWidth * 0.10 + offset + rowHeight,
                                       y: y - rowHeight * 0.2 + rowHeight * 0.82))
                offset += size * 0.018
            }
            NSBezierPath(rect: NSRect(x: x + paneWidth * 0.10, y: y - rowHeight * 0.2,
                                      width: paneWidth * 0.80, height: rowHeight * 0.82)).setClip()
            hatch.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
            NSGraphicsContext.current?.saveGraphicsState()
        }
        ink.withAlphaComponent(index == 1 && row == 3 ? 0.85 : 0.62).setFill()
        NSBezierPath(roundedRect: line, xRadius: rowHeight * 0.2, yRadius: rowHeight * 0.2).fill()
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { fputs("could not render the icon\n", stderr); exit(1) }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try? png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
