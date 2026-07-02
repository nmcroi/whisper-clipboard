from __future__ import annotations

from AppKit import NSColor, NSFont, NSFontWeightSemibold


def color(hex_value: str) -> NSColor:
    value = hex_value.lstrip("#")
    red, green, blue = (int(value[index : index + 2], 16) / 255 for index in (0, 2, 4))
    return NSColor.colorWithSRGBRed_green_blue_alpha_(red, green, blue, 1)


MARINE = color("#042648")
TERRA = color("#d97757")
BG = color("#faf9f5")
CARD = color("#fffdf9")
SAND = color("#e3dacc")
SOFTBLUE = color("#6a9bcc")
TEAL = color("#03739a")
TERRADARK = color("#b05638")
LIGHTTERRA = color("#fde1c6")


def heading_font(size: float) -> NSFont:
    return NSFont.fontWithName_size_("Georgia-Bold", size) or NSFont.systemFontOfSize_weight_(
        size, NSFontWeightSemibold
    )


def body_font(size: float, weight: str = "regular") -> NSFont:
    names = {
        "regular": "AvenirNext-Regular",
        "medium": "AvenirNext-Medium",
        "semibold": "AvenirNext-DemiBold",
    }
    return NSFont.fontWithName_size_(names[weight], size) or NSFont.systemFontOfSize_(size)
