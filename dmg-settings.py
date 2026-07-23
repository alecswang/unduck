# dmgbuild settings for the Unduck disk image. Driven by make-dmg.sh.
#
# Written for dmgbuild rather than the usual AppleScript-to-Finder dance because
# that dance needs Automation permission, prompts on first run, and fails outright
# in any headless or CI context. dmgbuild writes the .DS_Store itself, so the layout
# is deterministic and needs no permissions at all.
import os

app = os.environ.get("UNDUCK_APP", "build/Unduck.app")

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}

# Volume icon, so the mounted disk shows the duck instead of a generic drive.
icon = "assets/Unduck.icns"

background = "assets/dmg-background.png"

# Must match the background art: it is drawn at 640x400 points with the two icons
# centred on y=200 at x=170 and x=470, and the arrow drawn to sit between them.
window_rect = ((200, 180), (640, 400))
icon_size = 128
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (470, 200),
}

default_view = "icon-view"
show_icon_preview = False

# Every piece of window chrome is off. The background art is the instruction, and a
# toolbar or sidebar both covers it and invites the user to go wandering.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

text_size = 13
label_pos = "bottom"
