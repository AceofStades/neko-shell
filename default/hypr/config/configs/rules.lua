-- Window rules: dialogs and small tools float, picture-in-picture pins itself
-- in a corner, games go fullscreen. Rules for your own apps go in user.lua.

local count = 0
local function rule(match, fields)
  count = count + 1
  fields.name = "neko-default-" .. count
  fields.match = match
  hl.window_rule(fields)
end

-- Dialogs and settings tools
for _, class in ipairs({
  "nm-connection-editor", "blueman-manager", "pavucontrol", "org.pulseaudio.pavucontrol",
  "nwg-look", "qt5ct", "qt6ct", "kvantummanager", "mpv", "eog", "org.gnome.Loupe", "yad",
  "gnome-system-monitor", "org.gnome.Calculator", "hyprland-share-picker",
}) do
  rule({ class = "^(" .. class:gsub("%.", "\\.") .. ")$" }, { float = true })
end
rule({ class = "^(pavucontrol|org\\.pulseaudio\\.pavucontrol)$" }, { center = true, size = "(monitor_w*0.35) (monitor_h*0.4)" })
rule({ title = "^(Rename.*)$" }, { float = true })
rule({ initial_title = "^(Open Files?|Save As|Open Folder)$" }, { float = true })

-- File pickers from the portal
rule({ class = "^(xdg-desktop-portal-gtk)$" }, { float = true, center = true, size = "(monitor_w*0.6) (monitor_h*0.65)" })

-- Picture in picture, pinned small in the bottom corner
for _, title in ipairs({ "Picture-in-Picture", "Picture in picture" }) do
  rule({ title = "^(" .. title .. ")$" }, {
    float = true,
    pin = true,
    opacity = "1.0 override",
    size = "(monitor_w*0.25) (monitor_h*0.25)",
    move = "(monitor_w*0.72) (monitor_h*0.70)",
  })
end

-- Steam games fullscreen
rule({ class = "^(steam_app_\\d+)$" }, { tag = "+games" })
rule({ tag = "games*" }, { fullscreen = true })

-- The invisible bridge that lets X11 apps share Wayland screens
rule({ class = "^(xwaylandvideobridge)$" }, {
  opacity = "0.0 override",
  no_anim = true,
  no_initial_focus = true,
  max_size = "1 1",
  no_blur = true,
})

hl.layer_rule({ match = { namespace = "^selection$" }, no_anim = true })
