import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ProjectSweep-icon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let bounds = NSRect(origin: .zero, size: size)
NSColor.clear.setFill(); bounds.fill()
let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 54, dy: 54), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.64, blue: 0.62, alpha: 1), ending: NSColor(calibratedRed: 0.025, green: 0.30, blue: 0.34, alpha: 1))!.draw(in: tile, angle: -65)
let back = NSBezierPath(roundedRect: NSRect(x: 205, y: 370, width: 610, height: 355), xRadius: 46, yRadius: 46)
NSColor(calibratedWhite: 1, alpha: 0.35).setFill(); back.fill()
let tab = NSBezierPath(roundedRect: NSRect(x: 205, y: 642, width: 246, height: 115), xRadius: 35, yRadius: 35)
tab.fill()
let front = NSBezierPath(roundedRect: NSRect(x: 185, y: 282, width: 650, height: 371), xRadius: 49, yRadius: 49)
NSGradient(starting: .white, ending: NSColor(calibratedRed: 0.78, green: 0.95, blue: 0.93, alpha: 1))!.draw(in: front, angle: -90)
let check = NSBezierPath()
check.move(to: NSPoint(x: 420, y: 468)); check.line(to: NSPoint(x: 489, y: 402)); check.line(to: NSPoint(x: 627, y: 550))
check.lineWidth = 37; check.lineCapStyle = .round; check.lineJoinStyle = .round
NSColor(calibratedRed: 0.04, green: 0.47, blue: 0.47, alpha: 1).setStroke(); check.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
