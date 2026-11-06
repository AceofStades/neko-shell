# neko's colors for Vicinae; neko-theme-apps puts this in Vicinae's theme
# folder as "neko" each time the theme changes, and Vicinae picks it up live

[meta]
version = 1
name = "Neko"
description = "The current neko theme"
variant = "{{ mode }}"

[colors.core]
background = "{{ background }}"
foreground = "{{ foreground }}"
secondary_background = "{{ lighter_background }}"
border = "{{ mix background foreground 14% }}"
accent = "{{ accent }}"

[colors.accents]
blue = "{{ blue }}"
green = "{{ green }}"
magenta = "{{ magenta }}"
orange = "{{ orange }}"
purple = "{{ blue }}"
red = "{{ red }}"
yellow = "{{ yellow }}"
cyan = "{{ cyan }}"

[colors.text]
muted = "{{ dark_foreground }}"
placeholder = "{{ dark_foreground }}"

[colors.input]
border = "{{ mix background foreground 14% }}"
border_focus = "{{ accent }}"
border_error = "{{ red }}"

[colors.list.item.hover]
background = "{{ mix background foreground 6% }}"

[colors.list.item.selection]
background = "{{ mix background accent 18% }}"
secondary_background = "{{ mix background accent 26% }}"

[colors.grid.item]
background = "{{ lighter_background }}"
