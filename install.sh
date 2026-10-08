#!/bin/bash

# Set neko up for the current user, from this checkout:
#
#   ./install.sh             check what's needed, then set neko up
#   ./install.sh --check     only say which dependencies are missing
#   ./install.sh --uninstall take neko out again (your settings stay)
#   ./install.sh --yes       don't ask; take the defaults
#
# It installs no packages and never uses root: for anything missing it prints
# the command to run, from deps.txt. What it changes, all under your home:
#   ~/.local/bin/neko          a small launcher for the neko command
#   ~/.config/neko/env         machine settings (which Quickshell to run)
#   ~/.config/neko/shell.json  the bar and plugin layout (the default one)
#   your Hyprland Lua config   a marked block that loads neko and starts it,
#                              after a backup of the file next to it

set -uo pipefail

NEKO_PATH=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}
NEKO_CONFIG=$CONFIG_DIR/neko
HYPR_CONFIG=$CONFIG_DIR/hypr/hyprland.lua
LAUNCHER=$HOME/.local/bin/neko
MARK_BEGIN="-- >>> neko-shell >>>"
MARK_END="-- <<< neko-shell <<<"
LAUNCHER_MARK="# Installed by neko-shell's install.sh"

ASSUME_YES=0
MODE=install

bold=$'\e[1m'
dim=$'\e[2m'
red=$'\e[31m'
green=$'\e[32m'
yellow=$'\e[33m'
reset=$'\e[0m'
if [[ ! -t 1 ]]; then
  bold="" dim="" red="" green="" yellow="" reset=""
fi

say() { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$green" "$reset" "$bold" "$*" "$reset"; }
warn() { printf '%s!%s %s\n' "$yellow" "$reset" "$*"; }
fail() { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

# Yes or no, from the terminal even when stdin isn't one; --yes takes $2
ask() {
  local question=$1 default=${2:-n} answer
  if (( ASSUME_YES )) || [[ ! -r /dev/tty ]]; then
    [[ $default == y ]]
    return
  fi
  local hint="[y/N]"
  [[ $default == y ]] && hint="[Y/n]"
  printf '%s %s ' "$question" "$hint" > /dev/tty
  read -r answer < /dev/tty || answer=""
  answer=${answer:-$default}
  [[ $answer == [yY]* ]]
}

usage() {
  sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case $arg in
    --check) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown option: $arg (try --help)" ;;
  esac
done

(( EUID != 0 )) || fail "run this as yourself, not root: neko lives in your home"
[[ -f $NEKO_PATH/shell/shell.qml && -x $NEKO_PATH/bin/neko ]] ||
  fail "run install.sh from a neko-shell checkout (git clone, then ./install.sh)"

# ------------------------------------------------------------- dependencies

# Fills MISSING_REQUIRED, MISSING_RECOMMENDED, MISSING_OPTIONAL with lines of
# "package<TAB>what for"
check_dependencies() {
  MISSING_REQUIRED=() MISSING_RECOMMENDED=() MISSING_OPTIONAL=()
  local package need check purpose present
  while read -r package need check purpose; do
    [[ -z $package || $package == \#* ]] && continue
    present=0
    case $check in
      font:*)
        local family=${check#font:}
        family=${family//_/ }
        if [[ $family == monospace ]]; then
          [[ -n $(fc-list :spacing=mono family 2>/dev/null) ]] && present=1
        else
          # Not piped: grep -q quits early, and pipefail would count that against fc-list
          grep -qiF -- "$family" <<< "$(fc-list : family 2>/dev/null)" && present=1
        fi
        ;;
      lang:*)
        [[ -n $(fc-list ":lang=${check#lang:}" 2>/dev/null) ]] && present=1
        ;;
      *)
        command -v "$check" > /dev/null 2>&1 && present=1
        ;;
    esac
    # Quickshell answers to either name, or is the build env names
    if [[ $check == qs ]]; then
      command -v quickshell > /dev/null 2>&1 && present=1
      [[ -n $(configured_quickshell) ]] && present=1
    fi
    (( present )) && continue
    case $need in
      required) MISSING_REQUIRED+=("$package"$'\t'"$purpose") ;;
      recommended) MISSING_RECOMMENDED+=("$package"$'\t'"$purpose") ;;
      *) MISSING_OPTIONAL+=("$package"$'\t'"$purpose") ;;
    esac
  done < "$NEKO_PATH/deps.txt"
}

print_missing() {
  local title=$1
  shift
  (( $# > 0 )) || return 0
  say ""
  say "  ${bold}$title${reset}"
  local line
  for line in "$@"; do
    printf '    %-24s %s%s%s\n' "${line%%$'\t'*}" "$dim" "${line#*$'\t'}" "$reset"
  done
}

# The commands that would install what's missing, for the user to run
print_install_commands() {
  local repo=() aur=() line package
  for line in "$@"; do
    package=${line%%$'\t'*}
    if [[ $package == aur:* ]]; then
      aur+=("${package#aur:}")
    else
      repo+=("$package")
    fi
  done
  (( ${#repo[@]} + ${#aur[@]} > 0 )) || return 0
  say ""
  say "  To install them (Arch Linux):"
  (( ${#repo[@]} > 0 )) && say "    sudo pacman -S --needed ${repo[*]}"
  if (( ${#aur[@]} > 0 )); then
    local helper=""
    command -v paru > /dev/null 2>&1 && helper=paru
    [[ -z $helper ]] && command -v yay > /dev/null 2>&1 && helper=yay
    say "    ${helper:-<your AUR helper>} -S ${aur[*]}"
  fi
}

report_dependencies() {
  step "Checking dependencies"
  if ! command -v fc-list > /dev/null 2>&1; then
    warn "fontconfig isn't installed, so fonts can't be checked"
  fi
  check_dependencies
  if (( ${#MISSING_REQUIRED[@]} + ${#MISSING_RECOMMENDED[@]} + ${#MISSING_OPTIONAL[@]} == 0 )); then
    say "  Everything in deps.txt is installed."
    return 0
  fi
  print_missing "Required, missing:" "${MISSING_REQUIRED[@]}"
  print_missing "Recommended, missing (a core feature needs each):" "${MISSING_RECOMMENDED[@]}"
  print_missing "Optional, missing (one feature each):" "${MISSING_OPTIONAL[@]}"
  print_install_commands "${MISSING_REQUIRED[@]}" "${MISSING_RECOMMENDED[@]}"
  if (( ${#MISSING_OPTIONAL[@]} > 0 )); then
    say "  ${dim}Optional ones are listed in deps.txt; add whichever features you want.${reset}"
  fi
  return 0
}

# ------------------------------------------------------------------ install

# The Quickshell ~/.config/neko/env points at, if it's there and runs
configured_quickshell() {
  [[ -f $NEKO_CONFIG/env ]] || return 0
  local configured
  configured=$(set -a; source "$NEKO_CONFIG/env" > /dev/null 2>&1; echo "${NEKO_QUICKSHELL:-}")
  configured=${configured/#\~/$HOME}
  [[ -n $configured && -x $configured ]] && echo "$configured"
  return 0
}

find_quickshell() {
  local candidate
  for candidate in qs quickshell; do
    if command -v "$candidate" > /dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

install_launcher() {
  step "Installing the neko command"
  if [[ -e $LAUNCHER ]] && ! grep -qF "$LAUNCHER_MARK" "$LAUNCHER" 2> /dev/null; then
    warn "$LAUNCHER exists and isn't neko's; left alone. Run neko as $NEKO_PATH/bin/neko"
    return 0
  fi
  mkdir -p "$(dirname "$LAUNCHER")"
  cat > "$LAUNCHER" << EOF
#!/bin/bash
$LAUNCHER_MARK: runs the neko command from the checkout
export NEKO_PATH="$NEKO_PATH"
export PATH="\$NEKO_PATH/bin:\$PATH"
exec "\$NEKO_PATH/bin/neko" "\$@"
EOF
  chmod 755 "$LAUNCHER"
  say "  $LAUNCHER"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "~/.local/bin isn't on your PATH; add it to your shell's config to use 'neko' anywhere" ;;
  esac
}

install_config() {
  step "Setting up ~/.config/neko"
  mkdir -p "$NEKO_CONFIG"
  if [[ ! -f $NEKO_CONFIG/env ]]; then
    local quickshell
    quickshell=$(find_quickshell) || quickshell=""
    {
      say "# neko's machine settings, read by neko-session."
      say "# NEKO_QUICKSHELL: the Quickshell to run the shell with."
      say "# NEKO_REPLACES / NEKO_RESTORES: commands that stop and bring back the"
      say "#   bar or shell neko takes over from (e.g. 'pkill waybar' / 'waybar &')."
      say "# NEKO_WALLPAPER: a wallpaper to start with."
      say "NEKO_QUICKSHELL=${quickshell:-qs}"
    } > "$NEKO_CONFIG/env"
    say "  $NEKO_CONFIG/env"
    [[ -n $quickshell ]] || warn "Quickshell isn't installed yet; set NEKO_QUICKSHELL in $NEKO_CONFIG/env if it isn't 'qs'"
  else
    say "  $NEKO_CONFIG/env is already there; left as it is"
  fi
  if [[ ! -f $NEKO_CONFIG/shell.json ]]; then
    cp "$NEKO_PATH/config/neko/shell.json" "$NEKO_CONFIG/shell.json"
    say "  $NEKO_CONFIG/shell.json (the default bar)"
  else
    say "  $NEKO_CONFIG/shell.json is already there; left as it is"
  fi
}

hypr_has_neko() {
  grep -rqsE "default/hypr/neko\.lua|neko-session start" "$CONFIG_DIR/hypr" --include='*.lua'
}

install_hyprland() {
  step "Hooking neko into Hyprland"
  if [[ ! -f $HYPR_CONFIG ]]; then
    if [[ -f $CONFIG_DIR/hypr/hyprland.conf ]]; then
      warn "Your Hyprland config is hyprland.conf; neko's module needs a Lua config (hyprland.lua)."
    else
      warn "No Hyprland config found at $HYPR_CONFIG."
    fi
    say "  Once you have hyprland.lua, add this to it:"
    say "    dofile(\"$NEKO_PATH/default/hypr/neko.lua\")"
    say "    hl.on(\"hyprland.start\", function() hl.exec_cmd(\"$NEKO_PATH/bin/neko-session start\") end)"
    return 0
  fi
  if grep -qF -- "$MARK_BEGIN" "$HYPR_CONFIG"; then
    say "  Already hooked in ($HYPR_CONFIG)"
    return 0
  fi
  if hypr_has_neko; then
    say "  Your Hyprland config already loads neko; left as it is"
    return 0
  fi
  if ! ask "  Add neko to $HYPR_CONFIG (loads its module, starts it at login)?" y; then
    say "  Skipped. To do it yourself, add:"
    say "    dofile(\"$NEKO_PATH/default/hypr/neko.lua\")"
    say "    hl.on(\"hyprland.start\", function() hl.exec_cmd(\"$NEKO_PATH/bin/neko-session start\") end)"
    return 0
  fi
  local backup
  backup="$HYPR_CONFIG.before-neko-$(date +%Y%m%d-%H%M%S)"
  cp "$HYPR_CONFIG" "$backup"
  cat >> "$HYPR_CONFIG" << EOF

$MARK_BEGIN
-- Added by neko-shell's install.sh; ./install.sh --uninstall takes it out.
-- neko's Hyprland side: blur behind its surfaces, its keys, lid handling
dofile("$NEKO_PATH/default/hypr/neko.lua")
-- Start neko with the session
hl.on("hyprland.start", function()
  hl.exec_cmd("$NEKO_PATH/bin/neko-session start")
end)
$MARK_END
EOF
  say "  $HYPR_CONFIG (backup: $backup)"
}

check_lock() {
  step "Checking the lock screen"
  local profile
  for profile in neko-lock-password vlock hyprlock; do
    if [[ -f /etc/pam.d/$profile ]]; then
      say "  Passwords are checked with the PAM profile /etc/pam.d/$profile."
      return 0
    fi
  done
  warn "No PAM profile for the lock screen, so it won't lock. Create one (needs root):"
  say "    printf 'auth include system-local-login\\naccount include system-local-login\\n' | sudo tee /etc/pam.d/neko-lock-password"
  say "  (On Arch, the base kbd package's /etc/pam.d/vlock does the same.)"
}

offer_start() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || {
    say ""
    say "Log in to Hyprland and neko starts with it."
    return 0
  }
  if ask "Start neko now?" n; then
    NEKO_PATH="$NEKO_PATH" PATH="$NEKO_PATH/bin:$PATH" "$NEKO_PATH/bin/neko-session" start
  else
    say ""
    say "Start it any time with: neko session start"
  fi
}

# ---------------------------------------------------------------- uninstall

uninstall() {
  step "Taking neko out"
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && pgrep -f -- "-p $NEKO_PATH/shell\$" > /dev/null; then
    NEKO_PATH="$NEKO_PATH" PATH="$NEKO_PATH/bin:$PATH" "$NEKO_PATH/bin/neko-session" stop > /dev/null 2>&1 &&
      say "  Stopped the shell"
  fi
  if [[ -f $LAUNCHER ]] && grep -qF "$LAUNCHER_MARK" "$LAUNCHER"; then
    rm -f "$LAUNCHER"
    say "  Removed $LAUNCHER"
  fi
  if [[ -f $HYPR_CONFIG ]] && grep -qF -- "$MARK_BEGIN" "$HYPR_CONFIG"; then
    local backup
    backup="$HYPR_CONFIG.before-neko-uninstall-$(date +%Y%m%d-%H%M%S)"
    cp "$HYPR_CONFIG" "$backup"
    # The block, and the blank line install put before it
    awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
      held { held = 0; if ($0 == begin) { skipping = 1; next } print "" }
      !skipping && $0 == "" { held = 1; next }
      $0 == begin { skipping = 1; next }
      $0 == end { skipping = 0; next }
      !skipping { print }
      END { if (held) print "" }
    ' "$backup" > "$HYPR_CONFIG"
    say "  Took neko's block out of $HYPR_CONFIG (backup: $backup)"
  elif hypr_has_neko; then
    warn "Your Hyprland config loads neko outside install.sh's block; take those lines out yourself"
  fi
  say ""
  say "Your settings stay in $NEKO_CONFIG and ~/.local/state/neko; delete them to remove everything."
}

# --------------------------------------------------------------------- main

say "${bold}neko-shell${reset} ${dim}($NEKO_PATH)${reset}"

case $MODE in
  check)
    report_dependencies
    ;;
  uninstall)
    uninstall
    ;;
  install)
    report_dependencies
    if (( ${#MISSING_REQUIRED[@]} > 0 )); then
      say ""
      ask "Some required packages are missing; set neko up anyway?" n || {
        say "Install them, then run ./install.sh again."
        exit 1
      }
    fi
    install_launcher
    install_config
    install_hyprland
    check_lock
    offer_start
    say ""
    say "${green}Done.${reset} Run ${bold}neko${reset} for its commands; Super+Alt+Space opens the menu."
    ;;
esac
