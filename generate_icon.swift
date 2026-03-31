import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "CodexBianCeZhe-1024.png"
let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)

func superellipsePath(in rect: NSRect, exponent: CGFloat = 5.0, steps: Int = 256) -> NSBezierPath {
    precondition(steps >= 8)

    let path = NSBezierPath()
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let radiusX = rect.width / 2
    let radiusY = rect.height / 2
    let power = 2.0 / exponent

    func point(for angle: CGFloat) -> NSPoint {
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = center.x + radiusX * (cosine == 0 ? 0 : CGFloat(copysign(pow(abs(cosine), power), cosine)))
        let y = center.y + radiusY * (sine == 0 ? 0 : CGFloat(copysign(pow(abs(sine), power), sine)))
        return NSPoint(x: x, y: y)
    }

    path.move(to: point(for: 0))
    for index in 1...steps {
        let angle = (CGFloat(index) / CGFloat(steps)) * (.pi * 2)
        path.line(to: point(for: angle))
    }
    path.close()
    return path
}

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255.0
    let g = CGFloat((hex >> 8) & 0xff) / 255.0
    let b = CGFloat(hex & 0xff) / 255.0
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
}

func fill(_ path: NSBezierPath, _ hex: UInt32, alpha: CGFloat = 1.0) {
    color(hex, alpha: alpha).setFill()
    path.fill()
}

func stroke(_ path: NSBezierPath, _ hex: UInt32, _ width: CGFloat, alpha: CGFloat = 1.0) {
    color(hex, alpha: alpha).setStroke()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}

image.lockFocus()

let iconRect = NSRect(x: 28, y: 28, width: 968, height: 968)
let iconShape = superellipsePath(in: iconRect)

let badgeShadow = NSShadow()
badgeShadow.shadowColor = color(0x4E2F18, alpha: 0.16)
badgeShadow.shadowBlurRadius = 22
badgeShadow.shadowOffset = NSSize(width: 0, height: -8)

NSGraphicsContext.saveGraphicsState()
badgeShadow.set()
fill(iconShape, 0xF5E8CE)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
iconShape.addClip()

fill(iconShape, 0xF5E8CE)

let skyGlow = NSBezierPath(ovalIn: NSRect(x: 118, y: 626, width: 290, height: 290))
fill(skyGlow, 0xE68F33)

let distantHill = NSBezierPath()
distantHill.move(to: NSPoint(x: 0, y: 308))
distantHill.curve(to: NSPoint(x: 1024, y: 320),
                  controlPoint1: NSPoint(x: 220, y: 238),
                  controlPoint2: NSPoint(x: 770, y: 370))
distantHill.line(to: NSPoint(x: 1024, y: 0))
distantHill.line(to: NSPoint(x: 0, y: 0))
distantHill.close()
fill(distantHill, 0xC88B54)

let foreground = NSBezierPath()
foreground.move(to: NSPoint(x: 0, y: 220))
foreground.curve(to: NSPoint(x: 1024, y: 210),
                 controlPoint1: NSPoint(x: 320, y: 150),
                 controlPoint2: NSPoint(x: 700, y: 252))
foreground.line(to: NSPoint(x: 1024, y: 0))
foreground.line(to: NSPoint(x: 0, y: 0))
foreground.close()
fill(foreground, 0xAD6F3D)

let sceneShadow = NSBezierPath(ovalIn: NSRect(x: 170, y: 160, width: 700, height: 88))
fill(sceneShadow, 0x5B371E, alpha: 0.16)

let personHead = NSBezierPath(ovalIn: NSRect(x: 172, y: 546, width: 74, height: 82))
fill(personHead, 0xD89B67)

let hatBrim = NSBezierPath(roundedRect: NSRect(x: 152, y: 612, width: 122, height: 24), xRadius: 12, yRadius: 12)
fill(hatBrim, 0x8D2E22)

let hatTop = NSBezierPath(roundedRect: NSRect(x: 182, y: 632, width: 60, height: 44), xRadius: 12, yRadius: 12)
fill(hatTop, 0xA23927)

let personBody = NSBezierPath()
personBody.move(to: NSPoint(x: 208, y: 534))
personBody.line(to: NSPoint(x: 148, y: 342))
personBody.line(to: NSPoint(x: 280, y: 342))
personBody.close()
fill(personBody, 0xBA4730)

let belt = NSBezierPath(roundedRect: NSRect(x: 164, y: 376, width: 98, height: 18), xRadius: 9, yRadius: 9)
fill(belt, 0x563627)

let leftLeg = NSBezierPath(roundedRect: NSRect(x: 176, y: 214, width: 24, height: 142), xRadius: 10, yRadius: 10)
let rightLeg = NSBezierPath(roundedRect: NSRect(x: 224, y: 214, width: 24, height: 142), xRadius: 10, yRadius: 10)
fill(leftLeg, 0x4E3428)
fill(rightLeg, 0x4E3428)

let leftBoot = NSBezierPath(roundedRect: NSRect(x: 166, y: 198, width: 40, height: 24), xRadius: 8, yRadius: 8)
let rightBoot = NSBezierPath(roundedRect: NSRect(x: 214, y: 198, width: 40, height: 24), xRadius: 8, yRadius: 8)
fill(leftBoot, 0x211915)
fill(rightBoot, 0x211915)

let leftArm = NSBezierPath()
leftArm.move(to: NSPoint(x: 206, y: 468))
leftArm.line(to: NSPoint(x: 144, y: 418))
stroke(leftArm, 0xD89B67, 16)

let rightArm = NSBezierPath()
rightArm.move(to: NSPoint(x: 224, y: 486))
rightArm.line(to: NSPoint(x: 324, y: 566))
stroke(rightArm, 0xD89B67, 16)

let whipHandle = NSBezierPath()
whipHandle.move(to: NSPoint(x: 324, y: 566))
whipHandle.line(to: NSPoint(x: 354, y: 636))
stroke(whipHandle, 0x54392A, 10)

let whip = NSBezierPath()
whip.move(to: NSPoint(x: 352, y: 636))
whip.curve(to: NSPoint(x: 804, y: 690),
           controlPoint1: NSPoint(x: 472, y: 824),
           controlPoint2: NSPoint(x: 688, y: 780))
stroke(whip, 0x1D1916, 8)

let whipMotion1 = NSBezierPath()
whipMotion1.move(to: NSPoint(x: 806, y: 670))
whipMotion1.line(to: NSPoint(x: 842, y: 696))
stroke(whipMotion1, 0xE68F33, 8)

let whipMotion2 = NSBezierPath()
whipMotion2.move(to: NSPoint(x: 780, y: 700))
whipMotion2.line(to: NSPoint(x: 824, y: 734))
stroke(whipMotion2, 0xE68F33, 6)

let donkeyBody = NSBezierPath(roundedRect: NSRect(x: 482, y: 350, width: 304, height: 184), xRadius: 92, yRadius: 92)
fill(donkeyBody, 0x75655C)

let donkeyBelly = NSBezierPath(roundedRect: NSRect(x: 540, y: 336, width: 174, height: 118), xRadius: 56, yRadius: 56)
fill(donkeyBelly, 0xAB9380)

let donkeyNeck = NSBezierPath()
donkeyNeck.move(to: NSPoint(x: 562, y: 494))
donkeyNeck.line(to: NSPoint(x: 626, y: 634))
donkeyNeck.line(to: NSPoint(x: 686, y: 628))
donkeyNeck.line(to: NSPoint(x: 646, y: 484))
donkeyNeck.close()
fill(donkeyNeck, 0x75655C)

let donkeyHead = NSBezierPath(roundedRect: NSRect(x: 640, y: 540, width: 182, height: 110), xRadius: 42, yRadius: 42)
fill(donkeyHead, 0x75655C)

let donkeyMuzzle = NSBezierPath(roundedRect: NSRect(x: 760, y: 562, width: 96, height: 70), xRadius: 28, yRadius: 28)
fill(donkeyMuzzle, 0xB49E8A)

let earLeft = NSBezierPath()
earLeft.move(to: NSPoint(x: 714, y: 650))
earLeft.line(to: NSPoint(x: 708, y: 794))
earLeft.line(to: NSPoint(x: 748, y: 674))
earLeft.close()
fill(earLeft, 0x75655C)

let earRight = NSBezierPath()
earRight.move(to: NSPoint(x: 760, y: 648))
earRight.line(to: NSPoint(x: 784, y: 790))
earRight.line(to: NSPoint(x: 798, y: 668))
earRight.close()
fill(earRight, 0x75655C)

let donkeyEye = NSBezierPath(ovalIn: NSRect(x: 740, y: 598, width: 14, height: 14))
fill(donkeyEye, 0x181513)

let donkeyMouth = NSBezierPath()
donkeyMouth.move(to: NSPoint(x: 790, y: 582))
donkeyMouth.curve(to: NSPoint(x: 828, y: 588),
                  controlPoint1: NSPoint(x: 798, y: 574),
                  controlPoint2: NSPoint(x: 814, y: 576))
stroke(donkeyMouth, 0x5F4A3E, 5)

let tail = NSBezierPath()
tail.move(to: NSPoint(x: 492, y: 478))
tail.curve(to: NSPoint(x: 438, y: 542),
           controlPoint1: NSPoint(x: 458, y: 520),
           controlPoint2: NSPoint(x: 448, y: 542))
stroke(tail, 0x5E4E43, 8)

let tailTip = NSBezierPath(ovalIn: NSRect(x: 422, y: 530, width: 24, height: 36))
fill(tailTip, 0x2C231F)

let hindBackLeg = NSBezierPath()
hindBackLeg.move(to: NSPoint(x: 548, y: 352))
hindBackLeg.line(to: NSPoint(x: 534, y: 238))
hindBackLeg.line(to: NSPoint(x: 562, y: 238))
hindBackLeg.line(to: NSPoint(x: 572, y: 350))
hindBackLeg.close()
fill(hindBackLeg, 0x5E4D43)

let hindBackHoof = NSBezierPath(roundedRect: NSRect(x: 528, y: 224, width: 40, height: 22), xRadius: 8, yRadius: 8)
fill(hindBackHoof, 0x2E241F)

let hindFrontLeg = NSBezierPath()
hindFrontLeg.move(to: NSPoint(x: 606, y: 348))
hindFrontLeg.line(to: NSPoint(x: 618, y: 286))
hindFrontLeg.line(to: NSPoint(x: 632, y: 214))
hindFrontLeg.line(to: NSPoint(x: 660, y: 214))
hindFrontLeg.line(to: NSPoint(x: 642, y: 348))
hindFrontLeg.close()
fill(hindFrontLeg, 0x67564B)

let hindFrontHoof = NSBezierPath(roundedRect: NSRect(x: 624, y: 200, width: 42, height: 22), xRadius: 8, yRadius: 8)
fill(hindFrontHoof, 0x2E241F)

let frontBackLeg = NSBezierPath()
frontBackLeg.move(to: NSPoint(x: 690, y: 352))
frontBackLeg.line(to: NSPoint(x: 696, y: 252))
frontBackLeg.line(to: NSPoint(x: 722, y: 252))
frontBackLeg.line(to: NSPoint(x: 716, y: 352))
frontBackLeg.close()
fill(frontBackLeg, 0x5A493F)

let frontBackHoof = NSBezierPath(roundedRect: NSRect(x: 692, y: 238, width: 38, height: 22), xRadius: 8, yRadius: 8)
fill(frontBackHoof, 0x2E241F)

let frontFrontLeg = NSBezierPath()
frontFrontLeg.move(to: NSPoint(x: 748, y: 346))
frontFrontLeg.line(to: NSPoint(x: 760, y: 284))
frontFrontLeg.line(to: NSPoint(x: 778, y: 214))
frontFrontLeg.line(to: NSPoint(x: 808, y: 214))
frontFrontLeg.line(to: NSPoint(x: 786, y: 346))
frontFrontLeg.close()
fill(frontFrontLeg, 0x66554A)

let frontFrontHoof = NSBezierPath(roundedRect: NSRect(x: 774, y: 200, width: 40, height: 22), xRadius: 8, yRadius: 8)
fill(frontFrontHoof, 0x2E241F)

let lazyMark1 = NSBezierPath()
lazyMark1.move(to: NSPoint(x: 864, y: 692))
lazyMark1.line(to: NSPoint(x: 902, y: 730))
stroke(lazyMark1, 0x8D2E22, 8)

let lazyMark2 = NSBezierPath()
lazyMark2.move(to: NSPoint(x: 888, y: 666))
lazyMark2.line(to: NSPoint(x: 926, y: 704))
stroke(lazyMark2, 0x8D2E22, 6)

NSGraphicsContext.restoreGraphicsState()

let edge = superellipsePath(in: iconRect.insetBy(dx: 4, dy: 4))
stroke(edge, 0x7A4E2D, 18, alpha: 0.65)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    fputs("failed to create PNG data\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("failed to write icon: \(error)\n", stderr)
    exit(1)
}
