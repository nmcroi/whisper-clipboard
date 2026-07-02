from __future__ import annotations

import sys

from AppKit import (
    NSBezierPath,
    NSBitmapImageFileTypePNG,
    NSBitmapImageRep,
    NSColor,
    NSImage,
    NSLineCapStyleRound,
    NSMakePoint,
    NSMakeRect,
    NSMakeSize,
)


output_path = sys.argv[1] if len(sys.argv) > 1 else "app-icon-1024.png"
image = NSImage.alloc().initWithSize_(NSMakeSize(1024, 1024))
image.lockFocus()

NSColor.colorWithSRGBRed_green_blue_alpha_(250 / 255, 249 / 255, 245 / 255, 1).setFill()
NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
    NSMakeRect(64, 64, 896, 896), 210, 210
).fill()

NSColor.colorWithSRGBRed_green_blue_alpha_(4 / 255, 38 / 255, 72 / 255, 1).setFill()
NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(212, 212, 600, 600)).fill()

NSColor.colorWithSRGBRed_green_blue_alpha_(217 / 255, 119 / 255, 87 / 255, 1).setFill()
NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
    NSMakeRect(430, 410, 164, 320), 82, 82
).fill()

NSColor.colorWithSRGBRed_green_blue_alpha_(217 / 255, 119 / 255, 87 / 255, 1).setStroke()
cradle = NSBezierPath.bezierPath()
cradle.setLineWidth_(42)
cradle.setLineCapStyle_(NSLineCapStyleRound)
cradle.moveToPoint_(NSMakePoint(360, 550))
cradle.curveToPoint_controlPoint1_controlPoint2_(
    NSMakePoint(512, 342), NSMakePoint(360, 410), NSMakePoint(430, 342)
)
cradle.curveToPoint_controlPoint1_controlPoint2_(
    NSMakePoint(664, 550), NSMakePoint(594, 342), NSMakePoint(664, 410)
)
cradle.stroke()

stem = NSBezierPath.bezierPath()
stem.setLineWidth_(42)
stem.setLineCapStyle_(NSLineCapStyleRound)
stem.moveToPoint_(NSMakePoint(512, 342))
stem.lineToPoint_(NSMakePoint(512, 270))
stem.moveToPoint_(NSMakePoint(428, 270))
stem.lineToPoint_(NSMakePoint(596, 270))
stem.stroke()

image.unlockFocus()

bitmap = NSBitmapImageRep.imageRepWithData_(image.TIFFRepresentation())
png = bitmap.representationUsingType_properties_(NSBitmapImageFileTypePNG, {})
if not png.writeToFile_atomically_(output_path, True):
    raise RuntimeError(f"Could not write {output_path}")
