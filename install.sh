#!/bin/bash

# Set neko up for the current user, from this checkout:
#
#   ./install.sh               look at this machine, ask what you want, show
#                              the plan, then do it
#   ./install.sh --check       only say which dependencies are missing
#   ./install.sh --dry-run     ask, then show the plan and change nothing
#   ./install.sh --yes         don't ask; take the defaults (installs no
#                              packages and changes nothing outside your home)
#   ./install.sh --no-packages ask about everything but packages
#   ./install.sh --uninstall   take neko out again (your settings stay)
#
# It runs as you. Packages and system files (PAM, kernel modules, services)
# are only changed after you say yes to each, with the commands shown first,
# through sudo once for the lot. Without pacman it prints the commands instead.
# What it changes under your home:
#   ~/.local/bin/neko           a small launcher for the neko command
#   core/target/                neko-core, built from core/ with Rust, or else
#                               this version's release build, checksum verified
#   ~/.config/neko/env          machine settings (which Quickshell to run)
#   ~/.config/neko/shell.json   the bar and plugin layout (the default one)
#   ~/.config/neko/hardware.lua what it found about the hardware, for Hyprland
#   ~/.config/hypr              either a marked block in your hyprland.lua that
#                               loads neko, or neko's own config (yours backed
#                               up first), as you choose
#
# A fork publishing its own releases sets NEKO_RELEASES to its download URL
# (https://github.com/<owner>/<repo>/releases/download).

set -uo pipefail

NEKO_PATH=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}
NEKO_CONFIG=$CONFIG_DIR/neko
HYPR_DIR=$CONFIG_DIR/hypr
HYPR_CONFIG=$HYPR_DIR/hyprland.lua
STATE_FILE=$NEKO_CONFIG/install.state
HARDWARE_LUA=$NEKO_CONFIG/hardware.lua
LAUNCHER=$HOME/.local/bin/neko
MARK_BEGIN="-- >>> neko-shell >>>"
MARK_END="-- <<< neko-shell <<<"
NEKO_CONFIG_MARK="-- neko's Hyprland config. install.sh puts it in ~/.config/hypr"
LAUNCHER_MARK="# Installed by neko-shell's install.sh"
CORE=$NEKO_PATH/core/target/release/neko-core
NEKO_RELEASES=${NEKO_RELEASES:-https://github.com/AceofStades/neko-shell/releases/download}
STAMP=$(date +%Y%m%d-%H%M%S)

ASSUME_YES=0
DRY_RUN=0
NO_PACKAGES=0
MODE=install

bold=$'\e[1m'
dim=$'\e[2m'
red=$'\e[31m'
green=$'\e[32m'
yellow=$'\e[33m'
cyan=$'\e[36m'
reset=$'\e[0m'
if [[ ! -t 1 ]]; then
  bold="" dim="" red="" green="" yellow="" cyan="" reset=""
fi

say() { printf '%s\n' "$*"; }
step() { printf '\n%s==>%s %s%s%s\n' "$green" "$reset" "$bold" "$*" "$reset"; }
found() { printf '  %s•%s %s\n' "$cyan" "$reset" "$*"; }
warn() { printf '%s!%s %s\n' "$yellow" "$reset" "$*"; }
fail() { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case $arg in
    --check) MODE=check ;;
    --uninstall) MODE=uninstall ;;
    --dry-run) DRY_RUN=1 ;;
    --no-packages) NO_PACKAGES=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help) usage; exit 0 ;;
    *) fail "unknown option: $arg (try --help)" ;;
  esac
done

(( EUID != 0 )) || fail "run this as yourself, not root: neko lives in your home"
[[ -f $NEKO_PATH/shell/shell.qml && -x $NEKO_PATH/bin/neko ]] ||
  fail "run install.sh from a neko-shell folder: a git clone, or an unpacked release"

# --------------------------------------------------------------- questions

# Whether questions can be asked at all
interactive() {
  (( ! ASSUME_YES )) && [[ -r /dev/tty ]]
}

# Yes or no, from the terminal even when stdin isn't one; --yes takes $2
ask() {
  local question=$1 default=${2:-n} answer
  if ! interactive; then
    [[ $default == y ]]
    return
  fi
  local hint="[y/N]"
  [[ $default == y ]] && hint="[Y/n]"
  printf '%s?%s %s %s ' "$cyan" "$reset" "$question" "$hint" > /dev/tty
  read -r answer < /dev/tty || answer=""
  answer=${answer:-$default}
  [[ $answer == [yY]* ]]
}

# One of several options; prints the chosen index (from 1). $2 is the default.
choose() {
  local question=$1 default=$2 answer i
  shift 2
  if ! interactive; then
    echo "$default"
    return
  fi
  printf '%s?%s %s\n' "$cyan" "$reset" "$question" > /dev/tty
  for (( i = 1; i <= $#; i++ )); do
    if (( i == default )); then
      printf '    %s%d)%s %s %s(default)%s\n' "$bold" "$i" "$reset" "${!i}" "$dim" "$reset" > /dev/tty
    else
      printf '    %d) %s\n' "$i" "${!i}" > /dev/tty
    fi
  done
  while true; do
    printf '  choice [%d]: ' "$default" > /dev/tty
    read -r answer < /dev/tty || answer=""
    answer=${answer:-$default}
    if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= $# )); then
      echo "$answer"
      return
    fi
  done
}

# Any number of options; prints the chosen indexes (from 1), one per line.
# $2 is the default: "all", "none" or space-separated indexes.
choose_many() {
  local question=$1 default=$2 answer i
  shift 2
  local count=$#
  local picked=()
  if ! interactive; then
    answer=$default
  else
    printf '%s?%s %s\n' "$cyan" "$reset" "$question" > /dev/tty
    for (( i = 1; i <= count; i++ )); do
      printf '    %d) %s\n' "$i" "${!i}" > /dev/tty
    done
    printf '  numbers separated by spaces, "all" or "none" [%s]: ' "$default" > /dev/tty
    read -r answer < /dev/tty || answer=""
    answer=${answer:-$default}
  fi
  case $answer in
    all) for (( i = 1; i <= count; i++ )); do picked+=("$i"); done ;;
    none | "") ;;
    *)
      for i in $answer; do
        [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= count )) && picked+=("$i")
      done
      ;;
  esac
  (( ${#picked[@]} )) && printf '%s\n' "${picked[@]}"
  return 0
}

# ------------------------------------------------------------------- plan
#
# Questions only decide; nothing changes until the plan is shown and agreed
# to. Each step is a description and a command, run in order: user steps as
# you, root steps through sudo (asked for once).

PLAN_USER=()
PLAN_USER_TEXT=()
PLAN_ROOT=()
PLAN_ROOT_TEXT=()
REPO_PACKAGES=()
AUR_PACKAGES=()
SERVICES=()
NOTES=()

plan_user() { PLAN_USER_TEXT+=("$1"); PLAN_USER+=("$2"); }
plan_root() { PLAN_ROOT_TEXT+=("$1"); PLAN_ROOT+=("$2"); }
note() { NOTES+=("$1"); }

# Queue a package by deps.txt's naming: "aur:<name>" comes from the AUR
want_package() {
  local package=$1 existing
  for existing in "${REPO_PACKAGES[@]}" "${AUR_PACKAGES[@]}"; do
    [[ $existing == "${package#aur:}" ]] && return 0
  done
  if [[ $package == aur:* ]]; then
    AUR_PACKAGES+=("${package#aur:}")
  else
    REPO_PACKAGES+=("$package")
  fi
}

package_installed() {
  command -v pacman > /dev/null 2>&1 && pacman -Qq "${1#aur:}" > /dev/null 2>&1
}

# A command, a file's whole content through sudo tee, shown in the plan
quote() { printf '%q' "$1"; }

# -------------------------------------------------------------- the system

DISTRO_PACMAN=0
AUR_HELPER=""

probe_system() {
  command -v pacman > /dev/null 2>&1 && DISTRO_PACMAN=1
  local helper
  for helper in paru yay; do
    if command -v "$helper" > /dev/null 2>&1; then
      AUR_HELPER=$helper
      break
    fi
  done
}

# ---------------------------------------------------------------- hardware

HW_IR_CAMERA=""        # its stable /dev/v4l/by-path link
HW_FINGERPRINT=""      # the reader's name
HW_ASUS=0
HW_LAPTOP=0
HW_KBD_BACKLIGHT=0
HW_NVIDIA=0
HW_HYBRID=0
HW_EXTERNAL_DISPLAYS=0
HW_BLUETOOTH=0
HW_WEBCAM=0
HW_MODEL=""

# The IR camera Howdy looks through: a video node offering only greyscale
find_ir_camera() {
  local node name formats link
  for node in /dev/video*; do
    [[ -c $node ]] || continue
    if command -v v4l2-ctl > /dev/null 2>&1; then
      formats=$(v4l2-ctl -d "$node" --list-formats 2> /dev/null | grep -oE "'[A-Z0-9]{4}'" | tr -d "'" | tr '\n' ' ')
    else
      formats=""
    fi
    name=$(cat "/sys/class/video4linux/${node##*/}/name" 2> /dev/null)
    # Greyscale only, or a name that says it's infrared
    if [[ $formats == "GREY " || ( -z $formats && $name =~ (IR|[Ii]nfrared) ) ]]; then
      for link in /dev/v4l/by-path/*; do
        if [[ $(readlink -f "$link") == "$node" ]]; then
          echo "$link"
          return 0
        fi
      done
      echo "$node"
      return 0
    fi
  done
  return 1
}

# A fingerprint reader on USB: by its vendor (the makers libfprint supports),
# or a product name that says so
find_fingerprint() {
  local device vendor product
  for device in /sys/bus/usb/devices/*; do
    [[ -f $device/idVendor ]] || continue
    vendor=$(< "$device/idVendor")
    product=$(cat "$device/product" 2> /dev/null)
    if [[ $product =~ [Ff]inger ]] || [[ $vendor =~ ^(06cb|27c6|138a|10a5|1c7a|147e|2808|298d)$ && ( -z $product || $product =~ (FPC|[Ff]ingerprint|Biometric|Prometheus) ) ]]; then
      echo "${product:-USB $vendor reader}"
      return 0
    fi
  done
  return 1
}

probe_hardware() {
  step "Looking at this machine"
  local vendor product
  vendor=$(cat /sys/class/dmi/id/sys_vendor 2> /dev/null)
  product=$(cat /sys/class/dmi/id/product_name 2> /dev/null)
  HW_MODEL="$vendor $product"
  [[ -n ${HW_MODEL// } ]] && found "$HW_MODEL"

  [[ $vendor =~ ASUS ]] && HW_ASUS=1
  compgen -G "/sys/class/power_supply/BAT*" > /dev/null && HW_LAPTOP=1
  compgen -G "/sys/class/leds/*kbd_backlight*" > /dev/null && HW_KBD_BACKLIGHT=1
  compgen -G "/sys/class/bluetooth/hci*" > /dev/null && HW_BLUETOOTH=1
  (( HW_LAPTOP )) && found "a laptop (battery found)"
  (( HW_ASUS )) && found "an ASUS machine"
  (( HW_KBD_BACKLIGHT )) && found "a backlit keyboard"
  (( HW_BLUETOOTH )) && found "a Bluetooth adapter"

  # GPUs: NVIDIA alone, or beside an Intel or AMD one (a hybrid laptop)
  local gpus=""
  if command -v lspci > /dev/null 2>&1; then
    gpus=$(lspci -mm 2> /dev/null | grep -E '"(VGA compatible|3D|Display) controller"')
  fi
  if [[ $gpus =~ NVIDIA ]]; then
    HW_NVIDIA=1
    [[ $gpus =~ (Intel|AMD|ATI) ]] && HW_HYBRID=1
    if (( HW_HYBRID )); then found "an NVIDIA GPU beside an integrated one"; else found "an NVIDIA GPU"; fi
  fi

  # Displays plugged in other than the laptop's own
  local status connector
  for status in /sys/class/drm/card*-*/status; do
    [[ -f $status ]] || continue
    connector=${status%/status}
    connector=${connector##*/}
    [[ $connector =~ (eDP|LVDS|DSI) ]] && continue
    [[ $(< "$status") == connected ]] && (( HW_EXTERNAL_DISPLAYS++ ))
  done
  (( HW_EXTERNAL_DISPLAYS )) && found "$HW_EXTERNAL_DISPLAYS external display(s)"

  HW_IR_CAMERA=$(find_ir_camera) || HW_IR_CAMERA=""
  [[ -n $HW_IR_CAMERA ]] && found "an IR camera ($HW_IR_CAMERA)"
  compgen -G "/dev/video*" > /dev/null && HW_WEBCAM=1
  HW_FINGERPRINT=$(find_fingerprint) || HW_FINGERPRINT=""
  [[ -n $HW_FINGERPRINT ]] && found "a fingerprint reader ($HW_FINGERPRINT)"
  return 0
}

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

# The commands that would install the packages given, for the user to run
print_install_commands() {
  local repo=() aur=() package
  for package in "$@"; do
    package=${package%%$'\t'*}
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
  (( ${#aur[@]} > 0 )) && say "    ${AUR_HELPER:-<your AUR helper>} -S ${aur[*]}"
  return 0
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
  return 0
}

# Whether packages can be installed from here at all
can_install() {
  (( DISTRO_PACMAN && ! NO_PACKAGES )) && interactive
}

# Required and recommended packages: offered as two groups
decide_dependencies() {
  local line
  if (( ${#MISSING_REQUIRED[@]} )); then
    if can_install && ask "Install the ${#MISSING_REQUIRED[@]} required package(s)?" y; then
      for line in "${MISSING_REQUIRED[@]}"; do want_package "${line%%$'\t'*}"; done
    else
      REQUIRED_SKIPPED=1
    fi
  fi
  if (( ${#MISSING_RECOMMENDED[@]} )); then
    if can_install && ask "Install the ${#MISSING_RECOMMENDED[@]} recommended package(s)?" y; then
      for line in "${MISSING_RECOMMENDED[@]}"; do want_package "${line%%$'\t'*}"; done
    fi
  fi
}

REQUIRED_SKIPPED=0

# ------------------------------------------------------- hardware features

# PAM lines go in with their own backup, once, at the top of the file's auth
# stack ("sufficient": on a no it falls through to the password, so a broken
# reader never locks anyone out)
pam_add_line() {
  local file=$1 line=$2 module=$3
  plan_root "add '$line' to /etc/pam.d/$file" \
    "[[ -f /etc/pam.d/$file ]] || exit 0; grep -q '$module' /etc/pam.d/$file && exit 0; cp -n /etc/pam.d/$file /etc/pam.d/$file.before-neko; awk -v line=$(quote "$line") 'NR == 1 && /^#%PAM/ { print; print line; next } NR == 1 { print line } { print }' /etc/pam.d/$file > /etc/pam.d/$file.neko-new && mv /etc/pam.d/$file.neko-new /etc/pam.d/$file"
  echo "/etc/pam.d/$file" >> "$PAM_TOUCHED_LIST"
}

pam_write_file() {
  local file=$1 content=$2
  plan_root "write /etc/pam.d/$file" \
    "[[ -f /etc/pam.d/$file ]] && cp -n /etc/pam.d/$file /etc/pam.d/$file.before-neko; printf '%s\n' $(quote "$content") > /etc/pam.d/$file"
  echo "/etc/pam.d/$file" >> "$PAM_TOUCHED_LIST"
}

PAM_TOUCHED_LIST=$(mktemp)
trap 'rm -f "$PAM_TOUCHED_LIST"' EXIT

decide_face_unlock() {
  [[ -n $HW_IR_CAMERA ]] || return 0
  local have=0
  command -v howdy > /dev/null 2>&1 && have=1
  if (( have )) && [[ -r /usr/lib/security/pam_howdy.so ]] && grep -q 'pam_howdy' /etc/pam.d/system-auth 2> /dev/null; then
    found "Face unlock (Howdy) is set up already"
    warn_broad_howdy
    return 0
  fi
  step "Face unlock"
  say "  IR camera detected: $HW_IR_CAMERA"
  ask "Set up face unlock with Howdy (lock screen, and the places you pick next)?" y || return 0

  if (( ! have )); then
    if ! can_install; then
      note "Face unlock needs Howdy: ${AUR_HELPER:-<your AUR helper>} -S howdy-git, then run ./install.sh again"
      return 0
    fi
    want_package aur:howdy-git
  fi

  # Howdy's camera, set in its config once it's installed
  plan_root "point Howdy at the IR camera ($HW_IR_CAMERA)" \
    "for c in /etc/howdy/config.ini /usr/lib/security/howdy/config.ini; do [[ -f \$c ]] || continue; cp -n \$c \$c.before-neko; sed -i 's|^device_path *=.*|device_path = $HW_IR_CAMERA|' \$c; done"

  # The lock screen asks system-auth, which login and the display manager
  # share; sudo and polkit are separate
  pam_add_line system-auth "auth sufficient pam_howdy.so" pam_howdy
  local where
  where=$(choose_many "Where else should your face work?" "1 2" \
    "sudo (in a terminal)" \
    "polkit (apps asking for your password)")
  [[ $where == *1* ]] && pam_add_line sudo "auth sufficient pam_howdy.so" pam_howdy
  [[ $where == *2* ]] && pam_add_line polkit-1 "auth sufficient pam_howdy.so" pam_howdy

  if ask "Add your face now (Howdy takes a quick picture)?" y; then
    plan_root "add your face to Howdy" "howdy -U $(quote "$USER") add"
  else
    note "Add your face later with: sudo howdy add"
  fi
}

# Howdy on remote logins does nothing useful and widens what PAM accepts
warn_broad_howdy() {
  local file broad=()
  for file in sshd remote samba other; do
    grep -q 'pam_howdy' "/etc/pam.d/$file" 2> /dev/null && broad+=("$file")
  done
  (( ${#broad[@]} )) || return 0
  local IFS=,
  warn "Howdy is also in /etc/pam.d/{${broad[*]}}: face unlock there serves no one at the"
  say "  machine and only widens what's accepted. Consider taking those lines out (left as is)."
}

decide_fingerprint() {
  [[ -n $HW_FINGERPRINT ]] || return 0
  if [[ -f /etc/pam.d/neko-lock-fingerprint ]] && command -v fprintd-list > /dev/null 2>&1; then
    found "Fingerprint unlock is set up already"
    return 0
  fi
  step "Fingerprint unlock"
  say "  Fingerprint reader detected: $HW_FINGERPRINT"
  ask "Set up fingerprint unlock (lock screen, and the places you pick next)?" y || return 0
  if ! command -v fprintd-list > /dev/null 2>&1; then
    if ! can_install; then
      note "Fingerprint unlock needs fprintd: sudo pacman -S fprintd, then run ./install.sh again"
      return 0
    fi
    want_package fprintd
  fi
  pam_write_file neko-lock-fingerprint $'#%PAM-1.0\n# neko\'s lock screen reads fingerprints here, on their own conversation\nauth     required  pam_fprintd.so\naccount  required  pam_unix.so'
  local where
  where=$(choose_many "Where else should your fingerprint work?" "1 2" \
    "sudo (in a terminal)" \
    "polkit (apps asking for your password)")
  [[ $where == *1* ]] && pam_add_line sudo "auth sufficient pam_fprintd.so" pam_fprintd
  [[ $where == *2* ]] && pam_add_line polkit-1 "auth sufficient pam_fprintd.so" pam_fprintd
  if ask "Enroll a finger now?" y; then
    plan_user "enroll a finger (fprintd-enroll)" "fprintd-enroll"
  else
    note "Enroll a finger later with: fprintd-enroll"
  fi
}

decide_laptop() {
  if (( HW_ASUS )); then
    if ! command -v asusctl > /dev/null 2>&1; then
      step "ASUS"
      say "  asusctl gives the control center ASUS's power profiles and a battery charge limit."
      if ask "Install asusctl?" y && can_install; then
        want_package aur:asusctl
        SERVICES+=(asusd)
      fi
    fi
    if (( HW_LAPTOP )) && { command -v asusctl > /dev/null 2>&1 || [[ " ${AUR_PACKAGES[*]} " == *" asusctl "* ]]; }; then
      if ask "Stop charging at 80% to spare the battery (change it any time in the control center)?" n; then
        plan_user "set the battery charge limit to 80%" "NEKO_PATH=$(quote "$NEKO_PATH") PATH=$(quote "$NEKO_PATH/bin"):\$PATH neko-battery-limit set 80"
      fi
    fi
  elif (( HW_LAPTOP )) && ! command -v powerprofilesctl > /dev/null 2>&1; then
    step "Power"
    if ask "Install power-profiles-daemon (power modes in the control center)?" y && can_install; then
      want_package power-profiles-daemon
      SERVICES+=(power-profiles-daemon)
    fi
  fi
}

decide_bluetooth() {
  (( HW_BLUETOOTH )) || return 0
  if ! systemctl is-enabled bluetooth.service > /dev/null 2>&1; then
    step "Bluetooth"
    if ask "Turn the Bluetooth service on (the Bluetooth panel needs it)?" y; then
      command -v bluetoothctl > /dev/null 2>&1 || { can_install && want_package bluez-utils; }
      package_installed bluez || { can_install && want_package bluez; }
      SERVICES+=(bluetooth)
    fi
  fi
}

decide_gpu() {
  (( HW_NVIDIA )) || return 0
  step "Graphics"
  if (( HW_HYBRID )); then
    say "  The integrated GPU drives the screen; the NVIDIA one renders on request (prime-run)."
    say "  Hyprland needs nothing extra for that."
    GPU_ENV=hybrid
  elif ask "Set the environment Hyprland needs on an NVIDIA GPU?" y; then
    GPU_ENV=nvidia
  fi
  if ! package_installed nvidia-utils; then
    note "No NVIDIA driver found (nvidia-utils). Install nvidia-open (or your card's driver) and reboot."
  fi
}

GPU_ENV=""

decide_displays() {
  (( HW_EXTERNAL_DISPLAYS )) || return 0
  command -v ddcutil > /dev/null 2>&1 && return 0
  step "External displays"
  if ask "Control external monitors' brightness too (ddcutil, needs the i2c-dev module)?" y && can_install; then
    want_package ddcutil
    plan_root "load the i2c-dev module now and at every boot" \
      "printf 'i2c-dev\n' > /etc/modules-load.d/i2c-dev.conf; modprobe i2c-dev"
    plan_root "let $USER use the i2c bus" \
      "getent group i2c > /dev/null || groupadd --system i2c; usermod -aG i2c $(quote "$USER")"
    note "ddcutil works for you after your next login (the i2c group)."
  fi
}

# Optional features from deps.txt, offered by what this machine can use
decide_extras() {
  local candidates=() labels=() line package purpose
  for line in "${MISSING_OPTIONAL[@]}"; do
    package=${line%%$'\t'*}
    purpose=${line#*$'\t'}
    case ${package#aur:} in
      # Covered by the questions above, or never needed here
      howdy-git | fprintd | ddcutil | power-profiles-daemon | rust) continue ;;
      v4l-utils | ffmpeg) (( HW_WEBCAM )) || continue ;;
    esac
    candidates+=("$package")
    labels+=("$(printf '%-22s %s' "${package#aur:}" "$purpose")")
  done
  (( ${#candidates[@]} )) || return 0
  can_install || return 0
  step "Extras"
  local picked i
  picked=$(choose_many "Which of these do you want?" "none" "${labels[@]}")
  for i in $picked; do
    want_package "${candidates[i - 1]}"
  done
}

# A terminal and a file manager, for neko's own Hyprland config
TERMINAL=""
FILES=""

decide_apps() {
  local found_terms=() found_files=() app
  for app in ghostty kitty foot alacritty wezterm konsole gnome-terminal; do
    command -v "$app" > /dev/null 2>&1 && found_terms+=("$app")
  done
  for app in nautilus thunar dolphin nemo pcmanfm-qt pcmanfm; do
    command -v "$app" > /dev/null 2>&1 && found_files+=("$app")
  done

  if (( ${#found_terms[@]} == 1 )); then
    TERMINAL=${found_terms[0]}
  elif (( ${#found_terms[@]} > 1 )); then
    TERMINAL=${found_terms[$(( $(choose "Which terminal should Super+Return open?" 1 "${found_terms[@]}") - 1 ))]}
  elif can_install && ask "No terminal found. Install kitty?" y; then
    want_package kitty
    TERMINAL=kitty
  else
    TERMINAL=kitty
    note "No terminal is installed; neko's config opens kitty on Super+Return. Change it in ~/.config/hypr/configs/machine.lua."
  fi

  if (( ${#found_files[@]} == 1 )); then
    FILES=${found_files[0]}
  elif (( ${#found_files[@]} > 1 )); then
    FILES=${found_files[$(( $(choose "Which file manager should Super+E open?" 1 "${found_files[@]}") - 1 ))]}
  elif can_install && ask "No file manager found. Install Thunar?" y; then
    want_package thunar
    FILES=thunar
  else
    FILES=thunar
  fi
}

# ------------------------------------------------------------ Hyprland setup

HYPR_MODE=""     # hook | deploy | update | beside | skip

decide_hyprland() {
  step "Hyprland config"
  if [[ -f $HYPR_CONFIG ]] && grep -qF -- "$NEKO_CONFIG_MARK" "$HYPR_CONFIG"; then
    say "  You're on neko's Hyprland config."
    if ask "Update it to this version's (your user.lua stays; a backup is kept)?" y; then
      HYPR_MODE=update
    else
      HYPR_MODE=skip
    fi
  elif [[ -f $HYPR_CONFIG ]]; then
    say "  You have your own Hyprland config ($HYPR_CONFIG)."
    case $(choose "What should neko do with it?" 1 \
      "Keep mine, and hook neko into it (a marked block at the end)" \
      "Switch to neko's config (mine is backed up whole, and kept for reference)" \
      "Keep mine, and put neko's config beside it to compare (~/.config/hypr/neko-config)") in
      1) HYPR_MODE=hook ;;
      2) HYPR_MODE=deploy ;;
      3) HYPR_MODE=beside ;;
    esac
  elif [[ -f $HYPR_DIR/hyprland.conf ]]; then
    say "  Your Hyprland config is hyprland.conf; neko needs Hyprland's Lua config."
    if ask "Switch to neko's Lua config (your hyprland.conf is backed up and stops being read)?" y; then
      HYPR_MODE=deploy
    else
      HYPR_MODE=skip
      note "neko needs a Lua config. Add to your hyprland.lua: dofile(\"$NEKO_PATH/default/hypr/neko.lua\")"
    fi
  else
    say "  No Hyprland config yet."
    if ask "Use neko's Hyprland config?" y; then
      HYPR_MODE=deploy
    else
      HYPR_MODE=skip
    fi
  fi
  [[ $HYPR_MODE == deploy || $HYPR_MODE == update || $HYPR_MODE == beside ]] && decide_apps
  return 0
}

# What the marked block in your own config loads
hook_block() {
  cat << EOF

$MARK_BEGIN
-- Added by neko-shell's install.sh; ./install.sh --uninstall takes it out.
-- What install.sh found about the hardware (GPU environment)
local neko_hardware = io.open("$HARDWARE_LUA", "r")
if neko_hardware then neko_hardware:close(); dofile("$HARDWARE_LUA") end
-- neko's Hyprland side: blur behind its surfaces, its keys, lid handling
dofile("$NEKO_PATH/default/hypr/neko.lua")
-- Start neko with the session
hl.on("hyprland.start", function()
  hl.exec_cmd("$NEKO_PATH/bin/neko-session start")
end)
$MARK_END
EOF
}

hypr_has_neko() {
  grep -rqsE "default/hypr/neko\.lua|neko-session start" "$HYPR_DIR" --include='*.lua'
}

plan_hyprland() {
  local backup
  case $HYPR_MODE in
    hook)
      if grep -qF -- "$MARK_BEGIN" "$HYPR_CONFIG"; then
        # An older block: brought up to this version's
        plan_user "update neko's block in $HYPR_CONFIG" "replace_hook_block"
      elif hypr_has_neko; then
        say "  Your config already loads neko outside install.sh's block; left as it is."
        note "Your Hyprland config loads neko itself, so install.sh's GPU settings ($HARDWARE_LUA) aren't loaded unless you dofile it."
      else
        plan_user "add neko's block to $HYPR_CONFIG (backup next to it)" "append_hook_block"
      fi
      ;;
    deploy)
      [[ -d $HYPR_DIR ]] && plan_user "back up ~/.config/hypr to ~/.config/hypr.before-neko-$STAMP" "backup_hypr_dir"
      plan_user "put neko's Hyprland config in ~/.config/hypr" "deploy_hypr_config"
      ;;
    update)
      plan_user "update neko's Hyprland config in ~/.config/hypr (backup first)" "update_hypr_config"
      ;;
    beside)
      plan_user "put neko's Hyprland config in ~/.config/hypr/neko-config" "beside_hypr_config"
      ;;
  esac
  return 0
}

append_hook_block() {
  cp "$HYPR_CONFIG" "$HYPR_CONFIG.before-neko-$STAMP"
  hook_block >> "$HYPR_CONFIG"
  echo "hypr_backup=$HYPR_CONFIG.before-neko-$STAMP" >> "$STATE_FILE"
}

replace_hook_block() {
  cp "$HYPR_CONFIG" "$HYPR_CONFIG.before-neko-$STAMP"
  remove_hook_block "$HYPR_CONFIG.before-neko-$STAMP" > "$HYPR_CONFIG"
  hook_block >> "$HYPR_CONFIG"
}

# The file without neko's block, and the blank line install put before it
remove_hook_block() {
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
    held { held = 0; if ($0 == begin) { skipping = 1; next } print "" }
    !skipping && $0 == "" { held = 1; next }
    $0 == begin { skipping = 1; next }
    $0 == end { skipping = 0; next }
    !skipping { print }
    END { if (held) print "" }
  ' "$1"
}

backup_hypr_dir() {
  [[ -d $HYPR_DIR ]] || return 0
  cp -a "$HYPR_DIR" "$HYPR_DIR.before-neko-$STAMP"
  echo "hypr_dir_backup=$HYPR_DIR.before-neko-$STAMP" >> "$STATE_FILE"
}

# machine.lua: where neko is, and the apps the keys open
write_machine_lua() {
  local dir=$1
  mkdir -p "$dir/configs"
  cat > "$dir/configs/machine.lua" << EOF
-- Written by neko-shell's install.sh for this machine; run it again to change.
return {
  neko = "$NEKO_PATH",
  terminal = "$TERMINAL",
  files = "$FILES",
}
EOF
}

copy_neko_config() {
  local dir=$1
  mkdir -p "$dir/configs"
  cp "$NEKO_PATH/default/hypr/config/hyprland.lua" "$dir/hyprland.lua"
  cp "$NEKO_PATH"/default/hypr/config/configs/*.lua "$dir/configs/"
  write_machine_lua "$dir"
  [[ -f $dir/user.lua ]] || cp "$NEKO_PATH/default/hypr/config/user.lua" "$dir/user.lua"
}

deploy_hypr_config() {
  mkdir -p "$HYPR_DIR"
  # Your config's own modules would be loaded by nothing; they stay in the backup
  rm -f "$HYPR_CONFIG"
  [[ -d $HYPR_DIR/configs ]] && mv "$HYPR_DIR/configs" "$HYPR_DIR/configs.before-neko-$STAMP"
  [[ -f $HYPR_DIR/hyprland.conf ]] && mv "$HYPR_DIR/hyprland.conf" "$HYPR_DIR/hyprland.conf.before-neko-$STAMP"
  copy_neko_config "$HYPR_DIR"
  echo "hypr_mode=deploy" >> "$STATE_FILE"
}

update_hypr_config() {
  cp -a "$HYPR_DIR" "$HYPR_DIR.before-neko-update-$STAMP"
  copy_neko_config "$HYPR_DIR"
}

beside_hypr_config() {
  copy_neko_config "$HYPR_DIR/neko-config"
}

# hardware.lua: what Hyprland needs for the GPU found
plan_hardware_lua() {
  plan_user "write $HARDWARE_LUA (what Hyprland needs for this hardware)" "write_hardware_lua"
}

write_hardware_lua() {
  mkdir -p "$NEKO_CONFIG"
  {
    say "-- Written by neko-shell's install.sh from what it found on this machine"
    say "-- ($HW_MODEL); run it again to refresh. Hyprland loads it with neko."
    case $GPU_ENV in
      nvidia)
        say ""
        say "-- An NVIDIA GPU drives the screens"
        say 'hl.env("LIBVA_DRIVER_NAME", "nvidia")'
        say 'hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")'
        say 'hl.env("NVD_BACKEND", "direct")'
        say 'hl.config({ cursor = { no_hardware_cursors = true } })'
        ;;
      hybrid)
        say ""
        say "-- An integrated GPU drives the screens; run an app on the NVIDIA one with prime-run"
        ;;
    esac
  } > "$HARDWARE_LUA"
}

# ------------------------------------------------------------ neko itself

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

# neko-core (core/) is the Rust side of neko's helpers, which the bin/
# commands run. With Rust it's built here, as you; without it, the build
# published with this version's release is downloaded and used only if it
# matches the release's checksums. An update does the same again.
core_version() {
  sed -n 's/^version = "\(.*\)"$/\1/p' "$NEKO_PATH/core/Cargo.toml" | head -n 1
}

download_core() {
  local version=$1 asset=neko-core-x86_64-linux tmp
  if [[ $(uname -m) != x86_64 ]]; then
    warn "There's no prebuilt neko-core for $(uname -m); install Rust (cargo) and run ./install.sh again"
    return 1
  fi
  if ! command -v curl > /dev/null 2>&1; then
    warn "Downloading neko-core needs curl; install it (or Rust) and run ./install.sh again"
    return 1
  fi
  local url=$NEKO_RELEASES/v$version
  tmp=$(mktemp -d) || return 1
  say "  ${dim}$url/$asset${reset}"
  # Redirects (GitHub hands downloads to its storage) stay on HTTPS
  if ! curl -fsSL --proto-redir '=https' -o "$tmp/$asset" "$url/$asset" \
    || ! curl -fsSL --proto-redir '=https' -o "$tmp/SHA256SUMS" "$url/SHA256SUMS"; then
    warn "Couldn't download neko-core $version from $url"
    rm -rf "$tmp"
    return 1
  fi
  if ! (cd "$tmp" && grep -E "^[0-9a-f]{64}  $asset\$" SHA256SUMS | sha256sum --check --status --strict); then
    warn "The downloaded neko-core doesn't match the release's checksum, so it isn't used"
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$(dirname "$CORE")"
  install -m 755 "$tmp/$asset" "$CORE.new" && mv -f "$CORE.new" "$CORE"
  local status=$?
  rm -rf "$tmp"
  return $status
}

install_core() {
  local version
  version=$(core_version)
  if command -v cargo > /dev/null 2>&1; then
    say "  ${dim}cargo build --release (a minute or two the first time)${reset}"
    if cargo build --release --quiet --manifest-path "$NEKO_PATH/core/Cargo.toml"; then
      say "  Built $CORE"
      return 0
    fi
    warn "neko-core didn't build; trying the release build instead"
  fi
  if [[ -x $CORE && $("$CORE" version 2> /dev/null) == "$version" ]]; then
    say "  neko-core $version is already there"
    return 0
  fi
  if download_core "$version"; then
    say "  Downloaded neko-core $version; its checksum matches the release's"
  else
    warn "Without neko-core, the agents panel, calendars, face unlock and file pickers don't work"
  fi
}

install_launcher() {
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
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "~/.local/bin isn't on your PATH; add it to your shell's config to use 'neko' anywhere" ;;
  esac
}

install_config() {
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
  fi
  [[ -f $NEKO_CONFIG/shell.json ]] || cp "$NEKO_PATH/config/neko/shell.json" "$NEKO_CONFIG/shell.json"
}

# The lock screen's password check: plain pam_unix, so face and fingerprint
# unlock keep their own conversations
decide_lock() {
  local profile
  for profile in neko-lock-password vlock hyprlock; do
    [[ -f /etc/pam.d/$profile ]] && return 0
  done
  step "Lock screen"
  say "  The lock screen needs a PAM profile to check your password; without one it won't lock."
  if interactive && ask "Create /etc/pam.d/neko-lock-password?" y; then
    pam_write_file neko-lock-password $'#%PAM-1.0\n# neko\'s lock screen checks passwords here: pam_unix alone, so face and\n# fingerprint unlock stay on their own conversations\nauth     required  pam_unix.so\naccount  required  pam_unix.so'
  else
    note "Create the lock screen's PAM profile (as root):"
    note "  printf 'auth required pam_unix.so\\naccount required pam_unix.so\\n' | sudo tee /etc/pam.d/neko-lock-password"
  fi
}

# ------------------------------------------------------------- the plan

show_plan() {
  step "The plan"
  local i
  if (( ${#REPO_PACKAGES[@]} )); then
    say "  ${bold}Install (pacman):${reset} ${REPO_PACKAGES[*]}"
  fi
  if (( ${#AUR_PACKAGES[@]} )); then
    if [[ -n $AUR_HELPER ]]; then
      say "  ${bold}Install (AUR, $AUR_HELPER):${reset} ${AUR_PACKAGES[*]}"
    else
      say "  ${bold}From the AUR, no helper found:${reset} ${AUR_PACKAGES[*]} (install paru or yay, or build them yourself)"
    fi
  fi
  if (( ${#SERVICES[@]} )); then
    say "  ${bold}Turn on services:${reset} ${SERVICES[*]}"
  fi
  if (( ${#PLAN_ROOT[@]} )); then
    say "  ${bold}As root:${reset}"
    for i in "${!PLAN_ROOT_TEXT[@]}"; do say "    - ${PLAN_ROOT_TEXT[i]}"; done
  fi
  say "  ${bold}As you:${reset}"
  say "    - the neko command in ~/.local/bin, neko-core, ~/.config/neko"
  for i in "${!PLAN_USER_TEXT[@]}"; do say "    - ${PLAN_USER_TEXT[i]}"; done
  if (( DRY_RUN )); then
    say ""
    say "  ${dim}The exact root commands:${reset}"
    for i in "${!PLAN_ROOT[@]}"; do say "    ${dim}${PLAN_ROOT[i]}${reset}"; done
  fi
}

run_root_steps() {
  local needs_root=$(( ${#REPO_PACKAGES[@]} + ${#PLAN_ROOT[@]} + ${#SERVICES[@]} ))
  (( needs_root )) || { [[ ${#AUR_PACKAGES[@]} -gt 0 ]] && install_aur; return 0; }
  step "Asking for sudo, once, for the system steps"
  sudo -v || { warn "No sudo; the system steps are skipped"; return 1; }

  if (( ${#REPO_PACKAGES[@]} )); then
    step "Installing packages"
    sudo pacman -S --needed "${REPO_PACKAGES[@]}" || warn "pacman didn't finish; the rest carries on"
  fi
  install_aur

  local i
  for i in "${!PLAN_ROOT[@]}"; do
    step "${PLAN_ROOT_TEXT[i]}"
    if ! sudo bash -c "${PLAN_ROOT[i]}"; then
      warn "That didn't work; carrying on"
    fi
  done

  local service
  for service in "${SERVICES[@]}"; do
    sudo systemctl enable --now "$service.service" > /dev/null 2>&1 &&
      say "  $service is on" || warn "Couldn't turn $service on"
  done

  # The touched PAM files, for --uninstall to offer them back
  if [[ -s $PAM_TOUCHED_LIST ]]; then
    mkdir -p "$NEKO_CONFIG"
    sort -u "$PAM_TOUCHED_LIST" | sed 's/^/pam_touched=/' >> "$STATE_FILE"
  fi
}

install_aur() {
  (( ${#AUR_PACKAGES[@]} )) || return 0
  if [[ -z $AUR_HELPER ]]; then
    warn "From the AUR, not installed (no paru or yay): ${AUR_PACKAGES[*]}"
    return 0
  fi
  step "Installing from the AUR"
  "$AUR_HELPER" -S --needed "${AUR_PACKAGES[@]}" || warn "$AUR_HELPER didn't finish; the rest carries on"
}

run_user_steps() {
  step "Setting neko up"
  install_launcher
  say "  the neko command: $LAUNCHER"
  install_core
  install_config
  say "  ~/.config/neko"
  local i
  for i in "${!PLAN_USER[@]}"; do
    say "  ${PLAN_USER_TEXT[i]}"
    if [[ $(type -t "${PLAN_USER[i]}") == function ]]; then
      "${PLAN_USER[i]}" || warn "That didn't work; carrying on"
    else
      bash -c "${PLAN_USER[i]}" || warn "That didn't work; carrying on"
    fi
  done
}

offer_start() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || {
    say ""
    say "Log in to Hyprland and neko starts with it."
    return 0
  }
  if [[ $HYPR_MODE == deploy || $HYPR_MODE == update ]]; then
    ask "Reload Hyprland with the new config now?" y && hyprctl reload > /dev/null
  fi
  if ask "Start neko now?" n; then
    NEKO_PATH="$NEKO_PATH" PATH="$NEKO_PATH/bin:$PATH" "$NEKO_PATH/bin/neko-session" start
  else
    say ""
    say "Start it any time with: neko session start"
  fi
}

# ---------------------------------------------------------------- uninstall

state_values() {
  [[ -f $STATE_FILE ]] && sed -n "s/^$1=//p" "$STATE_FILE"
}

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

  # neko's own Hyprland config: offer the one it replaced
  local dir_backup
  dir_backup=$(state_values hypr_dir_backup | tail -n 1)
  if [[ -f $HYPR_CONFIG ]] && grep -qF -- "$NEKO_CONFIG_MARK" "$HYPR_CONFIG"; then
    if [[ -n $dir_backup && -d $dir_backup ]] && ask "Put back the Hyprland config you had before neko ($dir_backup)?" y; then
      mv "$HYPR_DIR" "$HYPR_DIR.neko-$STAMP"
      cp -a "$dir_backup" "$HYPR_DIR"
      say "  Restored $HYPR_DIR (neko's is in $HYPR_DIR.neko-$STAMP)"
    else
      warn "You're on neko's Hyprland config, which loads neko from $NEKO_PATH; it stays as it is"
    fi
  elif [[ -f $HYPR_CONFIG ]] && grep -qF -- "$MARK_BEGIN" "$HYPR_CONFIG"; then
    local backup="$HYPR_CONFIG.before-neko-uninstall-$STAMP"
    cp "$HYPR_CONFIG" "$backup"
    remove_hook_block "$backup" > "$HYPR_CONFIG"
    say "  Took neko's block out of $HYPR_CONFIG (backup: $backup)"
  elif hypr_has_neko; then
    warn "Your Hyprland config loads neko outside install.sh's block; take those lines out yourself"
  fi

  # System files install.sh changed, each with the backup it made
  local touched file
  touched=$(state_values pam_touched | sort -u)
  if [[ -n $touched ]]; then
    say ""
    say "  install.sh changed these PAM files (face or fingerprint unlock, the lock screen):"
    for file in $touched; do say "    $file"; done
    if ask "Put them back as they were (sudo)?" n; then
      for file in $touched; do
        if [[ -f $file.before-neko ]]; then
          sudo cp "$file.before-neko" "$file" && say "  Restored $file"
        else
          # A file install.sh created
          sudo rm -f "$file" && say "  Removed $file"
        fi
      done
    fi
  fi
  rm -f "$STATE_FILE"
  say ""
  say "Your settings stay in $NEKO_CONFIG and ~/.local/state/neko; delete them to remove everything."
  say "Packages install.sh installed stay installed."
}

# --------------------------------------------------------------------- main

say "${bold}neko-shell${reset} ${dim}($NEKO_PATH)${reset}"

case $MODE in
  check)
    probe_system
    report_dependencies
    print_install_commands "${MISSING_REQUIRED[@]}" "${MISSING_RECOMMENDED[@]}"
    ;;
  uninstall)
    uninstall
    ;;
  install)
    probe_system
    if (( ! DISTRO_PACMAN )); then
      warn "This isn't Arch Linux (no pacman): install.sh won't install packages, and says what's missing instead"
    fi
    if ! interactive; then
      say "${dim}Not asking (--yes, or no terminal): the defaults, no packages, nothing outside your home.${reset}"
    fi
    probe_hardware
    report_dependencies
    decide_dependencies
    if (( REQUIRED_SKIPPED )); then
      print_install_commands "${MISSING_REQUIRED[@]}"
      ask "Required packages are missing; set neko up anyway?" n || {
        say "Install them, then run ./install.sh again."
        exit 1
      }
    fi

    decide_hyprland
    decide_face_unlock
    decide_fingerprint
    decide_laptop
    decide_bluetooth
    decide_gpu
    decide_displays
    decide_extras
    decide_lock

    # Without a terminal to ask, root steps aren't run; they're printed
    if ! interactive && (( ${#PLAN_ROOT[@]} )); then
      for (( i = 0; i < ${#PLAN_ROOT_TEXT[@]}; i++ )); do note "Skipped (needs a yes): ${PLAN_ROOT_TEXT[i]}"; done
      PLAN_ROOT=() PLAN_ROOT_TEXT=()
    fi
    plan_hyprland
    plan_hardware_lua

    show_plan
    if (( DRY_RUN )); then
      say ""
      say "Dry run: nothing was changed."
      exit 0
    fi
    say ""
    ask "Go ahead?" y || { say "Nothing was changed."; exit 0; }

    mkdir -p "$NEKO_CONFIG"
    run_root_steps
    run_user_steps

    if (( ${#NOTES[@]} )); then
      step "Still to do"
      for note in "${NOTES[@]}"; do say "  $note"; done
    fi
    offer_start
    say ""
    say "${green}Done.${reset} Run ${bold}neko${reset} for its commands; Super+Alt+Space opens the menu."
    ;;
esac
