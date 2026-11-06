# neko's colors for Vicinae; neko-theme-apps puts this in Vicinae's theme
# folder as "neko" each time the theme changes, and Vicinae picks it up live.
# Glass: borders and fills are the foreground at a low opacity over the blur,
# and whatever is picked or focused takes neko's accent.

[meta]
version = 1
name = "Neko"
description = "The current neko theme"
variant = "{{ mode }}"

[colors.core]
background = "{{ background }}"
foreground = "{{ foreground }}"
secondary_background = "{{ lighter_background }}"
border = { name = "colors.core.foreground", opacity = 0.12 }
accent = "{{ accent }}"
accent_foreground = "{{ background }}"

[colors.main_window]
border = { name = "colors.core.foreground", opacity = 0.16 }
footer = { background = { name = "colors.core.foreground", opacity = 0.04 } }

[colors.settings_window]
border = { name = "colors.core.foreground", opacity = 0.16 }

[colors.accents]
blue = "{{ blue }}"
green = "{{ green }}"
magenta = "{{ magenta }}"
orange = "{{ orange }}"
purple = "{{ blue }}"
red = "{{ red }}"
yellow = "{{ yellow }}"
cyan = "{{ cyan }}"

[colors.shortcut]
border = { name = "colors.core.foreground", opacity = 0.16 }

[colors.text]
muted = "{{ dark_foreground }}"
placeholder = "{{ dark_foreground }}"
selection = { background = "{{ accent }}", foreground = "{{ background }}" }

[colors.text.links]
default = "{{ accent }}"
visited = "{{ blue }}"

[colors.input]
border = { name = "colors.core.foreground", opacity = 0.12 }
border_focus = "{{ accent }}"
border_error = "{{ red }}"

[colors.button.primary]
background = { name = "colors.core.foreground", opacity = 0.08 }
foreground = "{{ foreground }}"
hover = { background = { name = "colors.core.accent", opacity = 0.18 } }
focus = { outline = "colors.core.accent" }

[colors.list.item.hover]
background = { name = "colors.core.foreground", opacity = 0.06 }

[colors.list.item.selection]
background = { name = "colors.core.accent", opacity = 0.2 }
foreground = "{{ bright_foreground }}"
secondary_background = { name = "colors.core.accent", opacity = 0.28 }
secondary_foreground = "{{ bright_foreground }}"

[colors.grid.item]
background = { name = "colors.core.foreground", opacity = 0.05 }
hover = { outline = { name = "colors.core.accent", opacity = 0.5 } }
selection = { outline = "colors.core.accent" }

[colors.scrollbars]
background = { name = "colors.core.foreground", opacity = 0.18 }

[colors.loading]
bar = "{{ accent }}"
spinner = "{{ accent }}"
