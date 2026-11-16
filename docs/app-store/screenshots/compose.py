"""App Store screenshots for Second Chair, 1320 x 2868 (6.9-inch iPhone).

Each one: a device screenshot inside the website's iPhone 18 Pro frame
(re-rendered larger by render_frames.py), on the record's stage colour, with
a caption in IvyPresto Headline Light, roman with one italic phrase, as on
madewithmerritt.com/second-chair/.

    python3 compose.py
"""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).parent
SHOTS = HERE.parent / "shots"
OUT = HERE / "out"
SITE = Path.home() / "Desktop/Projects/Pivot Website/second-chair"
FONTS = Path.home() / "Library/Application Support/Adobe/CoreSync/plugins/livetype/.r"
ROMAN = FONTS / ".45414.otf"     # IvyPresto Headline Light
ITALIC = FONTS / ".45415.otf"    # IvyPresto Headline Light Italic
W, H = 1320, 2868

# From the site's assets/js/session.js.
RECORDS = {
    "low-sun": dict(stage="#cc231d", ink="#ffffff", wall=("#4a0907", "#b81c17")),
    "small-hours": dict(stage="#17214b", ink="#ffffff", wall=("#070b22", "#22336f")),
    "overcast": dict(stage="#cbd3c3", ink="#16201a", wall=("#3d4c40", "#8fa18e")),
    "ticket-hall": dict(stage="#e2a722", ink="#1a1406", wall=("#2a1f06", "#b8861a")),
    "tidewater": dict(stage="#0e5357", ink="#ffffff", wall=("#04282c", "#0f6a6c")),
    "allotment": dict(stage="#3a6535", ink="#ffffff", wall=("#142812", "#4c7f45")),
}
NIGHT = "#110e0c"
PAPER = "#f3eee6"
APERTURES = json.loads((SITE / "_docs/devices/apertures.json").read_text())


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def caption(canvas, lines, ink, top, size=112, leading=1.12):
    """Each line is a list of (text, italic) runs, centred as a whole."""
    draw = ImageDraw.Draw(canvas)
    fonts = {False: ImageFont.truetype(str(ROMAN), size), True: ImageFont.truetype(str(ITALIC), size)}
    y = top
    for runs in lines:
        widths = [draw.textlength(text, font=fonts[italic]) for text, italic in runs]
        x = (W - sum(widths)) / 2
        for (text, italic), width in zip(runs, widths):
            draw.text((x, y), text, font=fonts[italic], fill=ink)
            x += width
        y += size * leading
    return y


def device(screenshot, orientation, width):
    """The screenshot in the frame, scaled to `width`, with its drop shadow."""
    frame = Image.open(HERE / f"frame-{orientation}.png").convert("RGBA")
    scale = width / frame.width
    frame = frame.resize((width, round(frame.height * scale)), Image.LANCZOS)
    a = APERTURES[orientation]
    box = (round(a["left"] * frame.width), round(a["top"] * frame.height),
           round((a["left"] + a["width"]) * frame.width), round((a["top"] + a["height"]) * frame.height))
    screen = Image.open(screenshot).convert("RGBA").resize((box[2] - box[0], box[3] - box[1]), Image.LANCZOS)
    # The site rounds the screen just inside the window: 10.8 mm of 73.3.
    radius = round(min(screen.size) * 10.8 / 73.3)
    mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen.width - 1, screen.height - 1), radius=radius, fill=255)
    phone = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    phone.paste(screen, box[:2], mask)
    phone.alpha_composite(frame)
    return phone


def place(canvas, phone, x, y, shadow=0.38):
    alpha = phone.getchannel("A")
    blur = round(phone.width * 0.035)
    shade = Image.new("RGBA", phone.size, (0, 0, 0, 0))
    shade.putalpha(alpha.point(lambda v: int(v * shadow)))
    pad = blur * 3
    padded = Image.new("RGBA", (phone.width + 2 * pad, phone.height + 2 * pad), (0, 0, 0, 0))
    padded.paste(shade, (pad, pad))
    padded = padded.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(padded, (x - pad, y - pad + round(blur * 0.8)))
    canvas.alpha_composite(phone, (x, y))


def portrait(name, screenshot, record, lines, phone_width=1100, phone_top=620):
    r = RECORDS[record]
    canvas = Image.new("RGBA", (W, H), hex_rgb(r["stage"]) + (255,))
    caption(canvas, lines, r["ink"], top=190)
    phone = device(screenshot, "portrait", phone_width)
    place(canvas, phone, (W - phone.width) // 2, phone_top)
    save(canvas, name)


def standby_pair(name, shots, lines, background=NIGHT, ink="#f3eee6"):
    """Two phones on their sides, one above the other, each in StandBy."""
    canvas = Image.new("RGBA", (W, H), hex_rgb(background) + (255,))
    bottom = caption(canvas, lines, ink, top=190)
    width = 1240
    y = round(bottom) + 170
    for shot in shots:
        phone = device(shot, "landscape", width)
        place(canvas, phone, (W - phone.width) // 2, y)
        y += phone.height + 150
    save(canvas, name)


def save(canvas, name):
    OUT.mkdir(exist_ok=True)
    path = OUT / f"{name}.png"
    canvas.convert("RGB").save(path, optimize=True)
    print(path, canvas.size)


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "probe":
        standby_pair("probe-standby", [SHOTS / "probe.png", SHOTS / "probe.png"],
                     [[("And in StandBy,", False)], [("on the charger.", True)]])


def final():
    portrait("1-lock-screen", SHOTS / "lock-low-sun.png", "low-sun",
             [[("Your Mac’s music,", False)], [("on your Lock Screen.", True)]])
    standby_stack("2-standby", [SHOTS / "standby-low-sun.png", SHOTS / "standby-small-hours.png", SHOTS / "standby-ticket-hall.png"],
                  [[("And in StandBy,", False)], [("on the charger.", True)]])
    portrait("3-controls", SHOTS / "app-overcast.png", "overcast",
             [[("Press it here.", True)], [("It happens there.", False)]])
    callout("4-continue", SHOTS / "app-low-sun.png", (30, 1600, 1149, 2190),
            [[("Take your music with you.", False)], [("Then bring it back.", True)]])


def callout(name, screenshot, crop, lines, background=PAPER, ink="#16201a"):
    """The app, with one part of it enlarged on a card in front."""
    canvas = Image.new("RGBA", (W, H), hex_rgb(background) + (255,))
    bottom = caption(canvas, lines, ink, top=190)
    phone = device(screenshot, "portrait", 960)
    place(canvas, phone, (W - phone.width) // 2, round(bottom) + 120, shadow=0.25)
    part = Image.open(screenshot).convert("RGBA").crop(crop)
    width = 1080
    part = part.resize((width, round(part.height * width / part.width)), Image.LANCZOS)
    pad = 36
    card = Image.new("RGBA", (part.width + 2 * pad, part.height + 2 * pad), (0, 0, 0, 0))
    mask = Image.new("L", card.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, card.width - 1, card.height - 1), radius=64, fill=255)
    fill = Image.new("RGBA", card.size, part.getpixel((4, 4)))
    card.paste(fill, (0, 0), mask)
    card.alpha_composite(part, (pad, pad))
    card.putalpha(mask)
    place(canvas, card, (W - card.width) // 2, H - card.height - 260, shadow=0.45)
    save(canvas, name)


def standby_stack(name, shots, lines, background=NIGHT, ink="#f3eee6"):
    """Phones on their sides, one above another, each in StandBy, spread down the canvas."""
    canvas = Image.new("RGBA", (W, H), hex_rgb(background) + (255,))
    bottom = caption(canvas, lines, ink, top=190)
    phones = [device(shot, "landscape", 1180) for shot in shots]
    space = H - bottom - sum(p.height for p in phones)
    gap = space / (len(phones) + 1)
    y = bottom + gap * 0.9
    for phone in phones:
        place(canvas, phone, (W - phone.width) // 2, round(y))
        y += phone.height + gap
    save(canvas, name)


if __name__ == "__main__":
    final()
