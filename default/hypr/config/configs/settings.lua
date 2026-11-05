-- Look and behavior. Border colors come from the current neko theme, which
-- hyprland.lua loads after this.

hl.config({
  dwindle = {
    preserve_split = true,
    special_scale_factor = 0.8,
  },
  master = {
    new_on_top = true,
    mfact = 0.5,
  },
  general = {
    gaps_in = 4,
    gaps_out = 8,
    border_size = 1,
    resize_on_border = true,
    layout = "master",
  },
  decoration = {
    rounding_power = 2,
    active_opacity = 1.0,
    inactive_opacity = 0.9,
    fullscreen_opacity = 1.0,
    dim_inactive = true,
    dim_strength = 0.1,
    dim_special = 0.8,
    shadow = {
      enabled = false,
    },
    blur = {
      enabled = true,
      size = 6,
      passes = 2,
      ignore_opacity = true,
      new_optimizations = true,
      special = true,
    },
  },
  animations = {
    enabled = true,
  },
  input = {
    kb_layout = "us",
    repeat_rate = 50,
    repeat_delay = 300,
    numlock_by_default = true,
    follow_mouse = 1,
    float_switch_override_focus = 0,
    sensitivity = 0.2,
    accel_profile = "adaptive",
    touchpad = {
      disable_while_typing = true,
      natural_scroll = true,
      middle_button_emulation = true,
      tap_to_click = true,
      scroll_factor = 0.2,
    },
  },
  gestures = {
    workspace_swipe_distance = 400,
    workspace_swipe_invert = true,
    workspace_swipe_min_speed_to_force = 30,
    workspace_swipe_cancel_ratio = 0.5,
    workspace_swipe_create_new = true,
    workspace_swipe_forever = true,
  },
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    mouse_move_enables_dpms = true,
    enable_swallow = true,
    focus_on_activate = false,
    swallow_regex = "^(kitty|foot|Alacritty|com\\.mitchellh\\.ghostty|org\\.wezfurlong\\.wezterm)$",
  },
  binds = {
    workspace_back_and_forth = true,
    allow_workspace_cycles = true,
  },
  cursor = {
    enable_hyprcursor = true,
  },
})

-- Windows pop in and out, workspaces slide
hl.curve("extreme", { type = "bezier", points = { { 0.4, 0.0 }, { 0.3, 1.0 } } })
hl.curve("liner", { type = "bezier", points = { { 1, 1 }, { 1, 1 } } })

hl.animation({ leaf = "windows", enabled = true, speed = 2.8, bezier = "extreme", style = "popin 87%" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.8, bezier = "extreme", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 3.2, bezier = "extreme", style = "popin 87%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 2.8, bezier = "extreme", style = "slide" })
hl.animation({ leaf = "border", enabled = true, speed = 2, bezier = "liner" })
hl.animation({ leaf = "borderangle", enabled = false })
hl.animation({ leaf = "fade", enabled = true, speed = 2.5, bezier = "default" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 2.2, bezier = "extreme", style = "slide" })
hl.animation({ leaf = "layersIn", enabled = false })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.5, bezier = "extreme", style = "fade" })
