import os

# DMG settings for Speaky
# Used by: dmgbuild -s .github/dmgbuild-settings.py "Speaky" release/Speaky-<version>-<arch>.dmg

application = os.environ.get("APP_PATH", "release/Speaky.app")
app_name = os.path.basename(application)
background = os.environ.get("DMG_BACKGROUND", ".github/dmg-background.png")

# Volume settings
format = "UDZO"
size = None  # auto-calculate
files = [application]
symlinks = {"Applications": "/Applications"}

# Window appearance
window_rect = ((200, 160), (660, 400))
icon_size = 120
grid_spacing = 100
text_size = 14

# Icon positions (left = app, right = Applications)
icon_locations = {
    app_name: (165, 180),
    "Applications": (495, 180),
}

# Hide UI chrome
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
show_icon_preview = False

# Background
background = background if os.path.exists(background) else None
