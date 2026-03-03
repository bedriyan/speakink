#!/usr/bin/env python3
"""Generate DMG background image for Speaky with drag-to-Applications visual."""

from PIL import Image, ImageDraw, ImageFont
import sys

WIDTH, HEIGHT = 660, 400
OUTPUT = sys.argv[1] if len(sys.argv) > 1 else ".github/dmg-background.png"

# Colors (Speaky dark theme with amber accent)
BG_LEFT = (24, 24, 28)       # Dark — app source area
BG_RIGHT = (36, 36, 40)      # Slightly lighter — Applications target
AMBER = (245, 166, 35)       # Speaky amber accent
TEXT_PRIMARY = (249, 250, 251)
TEXT_SECONDARY = (156, 163, 175)
ARROW_COLOR = (245, 166, 35, 180)

img = Image.new("RGBA", (WIDTH, HEIGHT), BG_LEFT)
draw = ImageDraw.Draw(img)

# Right half background
draw.rectangle([(WIDTH // 2, 0), (WIDTH, HEIGHT)], fill=BG_RIGHT)

# Subtle divider line
draw.line([(WIDTH // 2, 40), (WIDTH // 2, HEIGHT - 40)], fill=(255, 255, 255, 20), width=1)

# Arrow in center pointing right
arrow_cx, arrow_cy = WIDTH // 2, 180
arrow_size = 24
# Arrow body
draw.rectangle(
    [(arrow_cx - 30, arrow_cy - 4), (arrow_cx + 15, arrow_cy + 4)],
    fill=ARROW_COLOR,
)
# Arrow head
draw.polygon(
    [
        (arrow_cx + 15, arrow_cy - arrow_size // 2 - 2),
        (arrow_cx + 38, arrow_cy),
        (arrow_cx + 15, arrow_cy + arrow_size // 2 + 2),
    ],
    fill=ARROW_COLOR,
)

# Load fonts
try:
    font_title = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    font_caption = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
except (OSError, IOError):
    try:
        font_title = ImageFont.truetype("/System/Library/Fonts/SFNSText.ttf", 22)
        font_caption = ImageFont.truetype("/System/Library/Fonts/SFNSText.ttf", 13)
    except (OSError, IOError):
        font_title = ImageFont.load_default()
        font_caption = ImageFont.load_default()

# Title at top
title = "Install Speaky"
bbox = draw.textbbox((0, 0), title, font=font_title)
tw = bbox[2] - bbox[0]
draw.text(((WIDTH - tw) // 2, 30), title, fill=TEXT_PRIMARY, font=font_title)

# Labels under icon positions
draw.text((130, 280), "Speaky.app", fill=TEXT_SECONDARY, font=font_caption, anchor="mt")
draw.text((495, 280), "Applications", fill=TEXT_SECONDARY, font=font_caption, anchor="mt")

# Bottom instruction text
instruction = "Drag Speaky to Applications to install"
bbox = draw.textbbox((0, 0), instruction, font=font_caption)
iw = bbox[2] - bbox[0]
draw.text(((WIDTH - iw) // 2, HEIGHT - 45), instruction, fill=TEXT_SECONDARY, font=font_caption)

img.save(OUTPUT, "PNG")
print(f"DMG background saved to {OUTPUT}")
