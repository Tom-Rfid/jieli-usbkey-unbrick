#!/usr/bin/env bash
# =====================================================================================================================
#  M-VAVE SMK-37 / FM-1: rescue a unit that no longer boots (JieLi chip, factory "UBOOT" mode)
#  Without opening the unit: the JieLi "USB key" goes through the USB cable, from a Raspberry Pi's GPIO.
#
#  TO RUN IT (on a Raspberry Pi 4 or 5, Raspberry Pi OS or Ubuntu), in the script's folder:
#      chmod +x rescue-en.sh
#      ./rescue-en.sh
#
#  What it does, from its menu:
#    - installs what is needed (Python, GPIO, USB and MIDI tools) and clones jl-uboot-tool
#    - shows the wiring (Pi 4 and Pi 5) with the USB cable's wire colours
#    - sends the JieLi "USB key" (0x16EF) from the GPIO to force the chip into UBOOT mode
#    - checks whether the keyboard is seen (lsusb / dmesg), backs up the flash (dump), keeps a log
#    - flashes: in UBOOT mode with M-Flasher (a graphical tool), or over MIDI if the unit still runs
#
#  Nothing is written to the keyboard unless you ask. Everything shown is also kept in the log.
# =====================================================================================================================

# ------------------------------------------------ settings (edit here or set as environment variables) -------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HERE/rescue-work}"                    # everything the script creates goes here
FIRMWARE="${FIRMWARE:-}"                              # a given .fwsc (otherwise: menu 9 to choose)
FW_SMK_ELITE="${FW_SMK_ELITE:-https://github.com/Tom-Rfid/OpenVALive_SMK-37/releases/download/preview-dev/openvalive-smk37-elite-0.0.3.fwsc}"
FW_SMK_PRO="${FW_SMK_PRO:-https://github.com/Tom-Rfid/OpenVALive_SMK-37/releases/download/preview-dev/openvalive-smk37-pro-0.0.3.fwsc}"
FW_FM1="${FW_FM1:-https://github.com/Tom-Rfid/OpenVALive_FM-1/releases/download/preview-dev/openvalive-fm1-0.0.3.fwsc}"
MFLASHER_VERSION="${MFLASHER_VERSION:-0.12.1}"
RESCUE_VERSION="2026-11-20 c"                   # (shown in every title: which script is running)        # https://github.com/jvitkauskas/m-flasher
INSTALLER_URL="${INSTALLER_URL:-https://github.com/Tom-Rfid/OpenVALive_FM-1/releases/latest/download/fm1_install.py}"
JLTOOL_GIT="${JLTOOL_GIT:-https://github.com/kagaimiq/jl-uboot-tool.git}"
DUMP_SIZE="${DUMP_SIZE:-0x100000}"                    # flash size to back up (1 MB on the SMK-37 Elite)
KEY_SECONDS="${KEY_SECONDS:-6}"                       # how long the key is sent
KEY_HALF_US="${KEY_HALF_US:-10}"                      # clock half-period in µs (10 ≈ 50 kHz; 25 slower)
GPIO_DP="${GPIO_DP:-17}"                              # D+ (clock): GPIO17 = physical pin 11
GPIO_DM="${GPIO_DM:-27}"                              # D- (data):  GPIO27 = physical pin 13
KEY_SOURCE="${KEY_SOURCE:-gpio}"                      # gpio: this Raspberry Pi sends the key; pico: a Pico (RP2040) does

VENV="$WORK/venv"
LOGDIR="$WORK/logs"
DUMPDIR="$WORK/backups"
LOG="$LOGDIR/session-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$WORK" "$LOGDIR" "$DUMPDIR"

# ------------------------------------------------ display -----------------------------------------------------------
B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; M=$'\e[35m'; W=$'\e[37m'; BL=$'\e[94m'; N=$'\e[0m'
say()  { echo -e "$*" | tee -a "$LOG"; }
ok()   { say "${G}✔ $*${N}"; }
warn() { say "${Y}⚠ $*${N}"; }
err()  { say "${R}✖ $*${N}"; }
pause(){ echo; read -rp "  Enter to go back to the menu… " _; }
run()  { say "${C}\$ $*${N}"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
title(){ clear; say "${B}${M}══════════════════════════════════════════════════════════════${N}";
         say "${B}  SMK-37 / FM-1 — rescue   ·   $*   ${N}${C}(script $RESCUE_VERSION)${N}";
         say "${B}${M}══════════════════════════════════════════════════════════════${N}"; }

pi_model() { tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "unknown"; }

# ------------------------------------------------ 1. the steps ------------------------------------------------------
steps() {
  title "The steps, in order"
  cat <<EOF | tee -a "$LOG"

  ${B}1.${N} Menu ${B}3${N}: install the tools (once, needs Internet).
  ${B}2.${N} Menu ${B}2${N}: do the wiring (Pi OFF while you plug the GPIO wires).
  ${B}3.${N} Menu ${B}4${N}: the unit's switch ${B}OFF${N}, Enter, ${B}THEN${N} switch ${B}ON${N} during the ${KEY_SECONDS} s.
       (Switched on before Enter, it boots normally as MIDI: the script says so, start again.)
  ${B}4.${N} Menu ${B}5${N}: check. We look for a ${B}4c4a${N} device (JieLi in UBOOT mode). ${B}A dark screen is normal${N} there.
       Nothing? Repeat step 3 (switch on earlier / later), then try menu ${B}8${N} (slower, or D+/D- swapped).
  ${B}5.${N} Menu ${B}6${N}: ${B}BACK UP the whole flash${N} (dump). NOTHING is written before you have this file.
  ${B}6.${N} Keep the dump somewhere safe (USB stick) and the log (menu ${B}7${N}): that is what it takes to analyse
       and repair, without touching the keyboard's calibration or Bluetooth.
  ${B}7.${N} Menu ${B}9${N}: choose the firmware (while there is Internet, any time).
  ${B}8.${N} Menu ${B}10${N}: in UBOOT mode, ${B}1${N} flashes the chosen firmware straight with M-Flasher's command line
       (you type ${B}yes${N}), ${B}2${N} opens its window; if the unit still runs, it flashes over MIDI.
  ${B}9.${N} ${B}Switch the unit off, wait 2 s, switch it on${N}: the logo, then the help. (It stays dark otherwise.)

  This session's log: ${C}$LOG${N}
EOF
  pause
}

# ------------------------------------------------ 2. wiring ---------------------------------------------------------
wiring() {
  title "Wiring — $(pi_model)"
  cat <<EOF | tee -a "$LOG"

  ${B}The cable:${N} a USB-A → USB-C cable (the USB-C end goes into the SMK-37 or the FM-1). Two ways:
   ${B}a)${N} without cutting: open the jacket in the middle, strip 5 mm on the black, green and white wires and
      solder the resistor and the wire to the Pi straight onto them. ${Y}Insulate every joint: nothing may touch.${N}
   ${B}b)${N} cutting: cut in the middle, join the wires colour to colour (solder or 3-way Wago),
      the 3rd entry takes the wire to the Pi.
  ${Y}The USB-A end stays in a USB port of the Pi: after the key, the Pi has to see the chip over USB.${N}
  (on screen: ${BL}blue${N} = the cable's white wire, to tell it apart)

     USB-A end (Pi's USB port)                  USB-C end (the unit)
       ${R}red   5V ════════════════════════════════════ red${N}        ← ${R}${B}NEVER to the GPIO${N}
       ${W}black GND ════════════════╦═════════════════ black${N}
                                 ${W}║${N}
                                 ${W}╚══════════════════════════════→ pin 9  (GND)${N}
       ${G}green D+  ════════════════╦═════════════════ green${N}
                                 ${G}║${N}
                                 ${G}╚═══[ 100 Ω ]══════════════════→ pin 11 (GPIO${GPIO_DP})  ★ D+${N}
       ${BL}white D-  ════════════════╦═════════════════ white${N}
                                 ${BL}║${N}
                                 ${BL}╚═══[ 100 Ω ]══════════════════→ pin 13 (GPIO${GPIO_DM})  ★ D-${N}

  ${B}Raspberry Pi 5 (and Pi 4) — 40-pin header, TOP VIEW${N}
  board flat, header at the top left, the fan connector to its right, the chip below it:

    ┌─────────────────────────────────────────────────────────────── TOP edge of the board
    │    2    4    6    8   10   12   14   16   18   20  …  40
    │   [5V] [5V] [GND][TX] [RX] [G18][GND][G23][G24][GND] …        [fan]
    │   [3V3][G2] [G3] [G4] [${W}GND${N}][${G}G17${N}][${BL}G27${N}][G22][3V3][G10] …
    │    1    3    5    7    9   11   13   15   17   19  …  39
    │                        ${W}▲${N}    ${G}▲${N}    ${BL}▲${N}
    │                      ${W}black${N} ${G}D+ ★${N} ${BL}D- ★${N}
    │                       ${W}GND${N}  ${G}green${N} ${BL}white${N}
    │                    (inner row, chip side)
    LEFT edge of the board

    From the left, on the BOTTOM row (chip side): 5th hole = ${W}black${N}, 6th = ${G}green D+${N}, 7th = ${BL}white D-${N}.

  ${B}Pi 4${N}: same header, same wiring ("gpiochip0"). ${B}Pi 5${N}: RP1 chip, the script finds it by itself.

  ${B}Multimeter check (beep mode), cable unplugged, BEFORE cutting:${N}
     USB-A plug facing you, plastic tongue down, contacts up, left to right:
        [1] 5 V red   [2] D- white   [3] D+ green   [4] GND black    (1 and 4 are longer)
     contact 3 ↔ green, contact 2 ↔ white, contact 4 ↔ black: it beeps.
     And NO wire may beep with another one (no short circuit).
EOF
  pause
}

# ------------------------------------------------ M-Flasher ---------------------------------------------------------
install_mflasher() {
  title "Installing M-Flasher ${MFLASHER_VERSION}"
  local arch deb url
  arch="$(dpkg --print-architecture)"           # arm64 (Raspberry Pi) or amd64 (PC)
  deb="$WORK/m-flasher_${MFLASHER_VERSION}-1_${arch}.deb"
  url="https://github.com/jvitkauskas/m-flasher/releases/download/v${MFLASHER_VERSION}/m-flasher_${MFLASHER_VERSION}-1_${arch}.deb"
  if ! curl -fL "$url" -o "$deb"; then err "Download failed ($url)."; pause; return 1; fi
  if ! run sudo apt-get install -y "$deb"; then err "M-Flasher install failed."; pause; return 1; fi
  command -v m-flasher >/dev/null 2>&1 && ok "M-Flasher installed: $(command -v m-flasher)" \
    || err "Installed, but no m-flasher command found."
  pause
}

# ------------------------------------------------ 3. install --------------------------------------------------------
install_all() {
  title "Installing the tools"
  run sudo apt-get update
  run sudo apt-get install -y git python3 python3-pip python3-venv python3-dev build-essential \
      usbutils libusb-1.0-0 libasound2-dev curl unzip python3-lgpio sg3-utils pkg-config cmake libjack-jackd2-dev \
    || warn "Some packages could not be installed (see above)."
  if [ ! -d "$VENV" ]; then run python3 -m venv --system-site-packages "$VENV"; fi
  run "$VENV/bin/pip" install --upgrade pip
  run "$VENV/bin/pip" install mido python-rtmidi pyusb pyserial
  "$VENV/bin/python" -c "import lgpio" 2>/dev/null || run "$VENV/bin/pip" install lgpio \
    || warn "lgpio not found: sudo apt install python3-lgpio"
  if [ -d "$WORK/jl-uboot-tool/.git" ]; then run git -C "$WORK/jl-uboot-tool" pull
  else run git clone "$JLTOOL_GIT" "$WORK/jl-uboot-tool"; fi
  if [ -f "$WORK/jl-uboot-tool/requirements.txt" ]; then
    run "$VENV/bin/pip" install -r "$WORK/jl-uboot-tool/requirements.txt"
  fi
  install_mflasher
  run curl -fsSL "${INSTALLER_URL%/*}/fm1ports.py" -o "$WORK/fm1ports.py"          # (fm1_install.py needs it)
  run curl -fsSL "$INSTALLER_URL" -o "$WORK/fm1_install.py" || warn "fm1_install.py not downloaded."
  write_key_script
  ok "Install done. Log: $LOG"
  pause
}

# ------------------------------------------------ the USB_KEY (Python, written by the script) -----------------------
write_key_script() {
  cat >"$WORK/usb_key.py" <<'PY'
# Sends the JieLi USB_KEY 0x16EF: D+ = clock (read on the rising edge), D- = data, most significant bit first.
import lgpio, sys, time
DP, DM, SECONDS, HALF_US = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
KEY = 0x16EF

def find_chip():                       # Pi 5: the RP1; Pi 4: the bcm2711; otherwise gpiochip0
    best = None
    for n in range(0, 8):
        try:
            h = lgpio.gpiochip_open(n)
        except Exception:
            continue
        info = lgpio.gpio_get_chip_info(h)
        lgpio.gpiochip_close(h)
        label = str(info[2]).lower()
        if "rp1" in label or "bcm2711" in label or "bcm2835" in label:
            return n, label
        if best is None:
            best = (n, label)
    return best or (0, "?")

chip, label = find_chip()
print(f"GPIO chip: gpiochip{chip} ({label})   D+ = GPIO{DP}   D- = GPIO{DM}   {SECONDS:.0f} s   half-period {HALF_US} µs")
h = lgpio.gpiochip_open(chip)
lgpio.gpio_claim_output(h, DP, 1)
lgpio.gpio_claim_output(h, DM, 1)

def wait(us):
    end = time.perf_counter_ns() + us * 1000
    while time.perf_counter_ns() < end:
        pass

print(">>> TURN THE UNIT'S SWITCH ON NOW <<<", flush=True)
t0, packets = time.time(), 0
try:
    while time.time() - t0 < SECONDS:
        for i in range(15, -1, -1):
            lgpio.gpio_write(h, DM, (KEY >> i) & 1)
            lgpio.gpio_write(h, DP, 0); wait(HALF_US)
            lgpio.gpio_write(h, DP, 1); wait(HALF_US)
        packets += 1
        wait(4 * HALF_US)
finally:
    lgpio.gpio_claim_input(h, DP)      # lines released: the chip takes the USB
    lgpio.gpio_claim_input(h, DM)
    lgpio.gpiochip_close(h)
print(f"{packets} keys sent. Lines released.")
PY
}

send_key() {
  if [ "$KEY_SOURCE" = "pico" ]; then          # the key comes from a Raspberry Pi Pico: here we only look
    title "USB_KEY sent by the Pico (RP2040)"
    say "The Pico (rp2040/usb_key.py): GP6 = D+ (green), GP7 = D- (white), GND = black. The USB-A end in THIS computer."
    say "1. The unit's switch ${B}OFF${N}.   2. Run usb_key.py on the Pico (Thonny: Run)."
    say "3. During its 6 s, switch ${B}ON${N}.   4. Come back here and press Enter."
    read -rp "  Enter when done… " _
    check_usb noPause
    pause; return
  fi
  title "Sending the USB_KEY"
  [ -f "$WORK/usb_key.py" ] || write_key_script
  say "${B}Before:${N} the ${B}unit's switch OFF${N}, the USB cable in the Pi, the 3 GPIO wires in place."
  say "${B}Then:${N} press Enter, the Pi sends the key for ${KEY_SECONDS} s, and ${B}DURING that time${N}"
  say "      turn the ${B}unit's switch ON${N} (ideally 1 second after Enter)."
  say "      The chip reads the key as it powers up: on before, or after the ${KEY_SECONDS} s, it does not work."
  say "${R}${B}⚠ THE ORDER MATTERS:${N} ${B}1. switch the unit OFF${N}   ${B}2. Enter here${N}   ${B}3. switch it ON${N} while the key goes."
  say "   Switched on before Enter, it boots normally (as MIDI) and the key does nothing."
  read -rp "  Is the unit switched OFF? [y/N] " off
  case "$off" in y|Y|o|O) ;; *) warn "Switch it off first, then menu 4 again."; pause; return ;; esac
  read -rp "  Enter to start the key, THEN switch the unit on… " _
  sudo dmesg -C 2>/dev/null
  run sudo "$VENV/bin/python" "$WORK/usb_key.py" "$GPIO_DP" "$GPIO_DM" "$KEY_SECONDS" "$KEY_HALF_US" \
    || err "The key script failed (lgpio installed? menu 3)."
  wait_device
  check_usb noPause
  pause
}

# the unit's USB state: uboot (4c4a, the chip's loader), normal (its firmware runs: MIDI), none
NORMAL_IDS="3654:7756|1209:0001|smk|fm-1|m-vave|sinco|openvalive"
usb_state() {
  if lsusb | grep -qi "4c4a:"; then echo uboot
  elif lsusb | grep -qiE "$NORMAL_IDS"; then echo normal
  else echo none; fi
}
normal_name() { lsusb | grep -iE "$NORMAL_IDS" | head -n 1 | cut -d' ' -f6-; }
# after the key: a few seconds for the chip to show up; nothing at all: the USB is enumerated again, once
wait_device() {
  for _ in 1 2 3 4 5 6; do [ "$(usb_state)" = none ] || return 0; sleep 1; done
  say "Nothing yet: the Pi's USB is restarted once to see the devices again…"
  for a in /sys/bus/usb/devices/usb*/authorized; do echo 0 | sudo tee "$a" >/dev/null; echo 1 | sudo tee "$a" >/dev/null; done
  for _ in 1 2 3 4; do [ "$(usb_state)" = none ] || return 0; sleep 1; done
}

# ------------------------------------------------ 5. detection ------------------------------------------------------
check_usb() {
  [ "$1" = "noPause" ] || title "Is the keyboard seen?"
  say "${B}lsusb:${N}"; run lsusb
  say "${B}dmesg (last USB lines):${N}"; sudo dmesg | grep -iE "usb|4c4a|jieli|uboot|scsi|sd[a-z]|midi" | tail -n 25 | tee -a "$LOG"
  case "$(usb_state)" in
    uboot)
      ok "JieLi 4c4a device found: the chip is in UBOOT mode. Next: menu 6 (backup)."
      say "   ${B}The unit's screen stays dark in this mode: that is normal.${N} Nothing is broken; switching it off leaves it."
      lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN | tee -a "$LOG"
      warn "Do NOT mount or format the disk the system may offer." ;;
    normal)
      err "The unit BOOTED NORMALLY ($(normal_name)): it runs as MIDI, not in UBOOT mode."
      say "   It was on before the key (or switched on too late). ${B}Switch it off, menu 4, Enter, THEN switch it on.${N}"
      say "   (The backup, menu 6, only works in UBOOT mode. To just reflash a unit that boots: menu 10, over MIDI.)" ;;
    *)
      warn "Nothing on USB. If the unit is on and its screen stays dark, the chip may have taken the key:"
      say "   menu 5 again in a few seconds. Otherwise menu 4 again (switch on a little earlier or later), or menu 8 (settings)." ;;
  esac
  [ "$1" = "noPause" ] || pause
}

# ------------------------------------------------ 6. backup ---------------------------------------------------------
dump_flash() {
  title "Backing up the whole flash (dump)"
  [ -d "$WORK/jl-uboot-tool" ] || { err "jl-uboot-tool missing: menu 3 first."; pause; return; }
  case "$(usb_state)" in
    uboot) ;;
    normal) err "The unit runs normally as MIDI ($(normal_name)): the backup only works in UBOOT mode (4c4a)."
            say "   Switch it off, menu 4, Enter, THEN switch it on; menu 5 must show 4c4a."; pause; return ;;
    *) warn "No 4c4a device seen: the backup will most likely fail (menu 4)." ;;
  esac
  local out="$DUMPDIR/flash-$(date +%Y%m%d-%H%M%S).bin"
  say "Size: ${B}$DUMP_SIZE${N} (change it: DUMP_SIZE=0x400000 ./rescue-en.sh)"
  say "1) automatic: the script sends \"read 0 $DUMP_SIZE …\" then \"exit\" to the tool"
  say "2) by hand:   you type in the tool yourself"
  read -rp "  Choice [1/2]: " c
  cd "$WORK/jl-uboot-tool" || return
  if [ "$c" = "2" ]; then
    say "In the tool, type:   ${B}read 0 $DUMP_SIZE $out${N}   then   ${B}exit${N}"
    sudo "$VENV/bin/python" jluboottool.py 2>&1 | tee -a "$LOG"
  else
    printf 'read 0 %s %s\nexit\n' "$DUMP_SIZE" "$out" | sudo "$VENV/bin/python" jluboottool.py 2>&1 | tee -a "$LOG"
  fi
  cd "$HERE" || return
  if [ -s "$out" ]; then
    sudo chown "$(id -u):$(id -g)" "$out" 2>/dev/null
    ok "Backup: $out ($(stat -c %s "$out") bytes)"
    say "The unit stays in UBOOT mode (dark screen): menu 9 then 10 to write a firmware, or switch it off to leave it."
    sha256sum "$out" | tee -a "$LOG" | tee "$out.sha256" >/dev/null
    cp "$out" "$out.copy" && ok "A safety copy: $out.copy (put one on a USB stick too)"
  else
    err "No backup file. Read the tool's message above (menu 7 for the log)."
    warn "If the tool does not recognise the chip, keep the log and try nothing else."
  fi
  pause
}

# ------------------------------------------------ 7. log ------------------------------------------------------------
journal() {
  title "Log and diagnostics"
  local f="$LOGDIR/diagnostics-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "=== $(date)   $(pi_model)   $(uname -a)"
    echo "=== lsusb";  lsusb
    echo "=== lsusb -t"; lsusb -t
    echo "=== lsblk"; lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN
    echo "=== dmesg (last 150 lines)"; sudo dmesg | tail -n 150
    echo "=== aconnect -l (MIDI)"; aconnect -l 2>&1
    echo "=== session log ($LOG)"; cat "$LOG"
  } >"$f" 2>&1
  less -R "$f"
  ok "Diagnostics saved: $f   (the file to share when asking for help)"
  pause
}

# ------------------------------------------------ 8. key settings ---------------------------------------------------
settings() {
  title "Key settings"
  say "Now: D+ = GPIO$GPIO_DP   D- = GPIO$GPIO_DM   ${KEY_SECONDS} s   half-period ${KEY_HALF_US} µs"
  say "  1) swap D+ and D-        2) slower (25 µs)        3) faster (5 µs)"
  say "  4) 10 s                  5) back to the defaults"
  say "  6) the key comes from this Raspberry Pi (GPIO) / a Pico (RP2040): now ${KEY_SOURCE}"
  read -rp "  Choice: " c
  case "$c" in
    1) t=$GPIO_DP; GPIO_DP=$GPIO_DM; GPIO_DM=$t ;;
    2) KEY_HALF_US=25 ;;
    3) KEY_HALF_US=5 ;;
    4) KEY_SECONDS=10 ;;
    5) GPIO_DP=17; GPIO_DM=27; KEY_SECONDS=6; KEY_HALF_US=10 ;;
    6) [ "$KEY_SOURCE" = "pico" ] && KEY_SOURCE=gpio || KEY_SOURCE=pico ;;
  esac
  ok "Now: D+ = GPIO$GPIO_DP   D- = GPIO$GPIO_DM   ${KEY_SECONDS} s   ${KEY_HALF_US} µs"
  pause
}

# ------------------------------------------------ 9. flash ----------------------------------------------------------
# the .fwsc files next to the script or in the folder above (the unzipped firmware's folder)
local_fwsc() { ls "$HERE"/*.fwsc "$HERE"/../*.fwsc 2>/dev/null | while read -r f; do readlink -f "$f"; done | sort -u; }
find_firmware() {
  if [ -n "$FIRMWARE" ] && [ -f "$FIRMWARE" ]; then echo "$FIRMWARE"; return; fi
  local n; n=$(local_fwsc | grep -c .)
  [ "$n" = "1" ] && local_fwsc
}

reflash() {
  title "Flashing the firmware"
  if lsusb | grep -qi "4c4a:"; then             # UBOOT mode: M-Flasher (JieLi USB/SCSI protocol)
    ok "Unit in UBOOT mode ($(lsusb | grep -i 4c4a: | head -n 1 | cut -d' ' -f6-))"
    command -v m-flasher >/dev/null 2>&1 || install_mflasher || return
    sudo modprobe sg 2>/dev/null                  # (the generic SCSI driver it uses)
    local fw; fw="$(find_firmware)"
    [ -n "$fw" ] || { warn "No firmware chosen yet: menu 9 first."; choose_fw; fw="$(find_firmware)"; title "Flashing the firmware"; }
    say "Firmware: ${B}${fw:-none}${N}"
    say "Flashing goes through ${B}M-Flasher${N}. It first backs up the whole flash (AUTO BACKUP), leaves the bootloader,"
    say "the calibration (C1) and the pairings (7B) alone, then restarts the unit."
    say "  ${B}1${N}  Flash ${B}here${N}, straight with this firmware (M-Flasher's command line) — recommended"
    say "  ${B}2${N}  Open M-Flasher's window (FIRMWARE FILE > CHOOSE FILE, FLASH FIRMWARE, REVIEW & FLASH)"
    read -rp "  Choice [1/2]: " c
    if [ "$c" = "2" ]; then
      run m-flasher
      say "${B}After flashing: switch the unit off, wait 2 seconds, switch it on${N} (the screen stays dark otherwise)."
      pause; return
    fi
    [ -n "$fw" ] || { err "No firmware: menu 9."; pause; return; }
    local board=""                              # (the file's name, not the folder it is in)
    case "$(basename "$fw" | tr 'A-Z' 'a-z')" in *smk37*|*smk-37*) board=smk37;; *fm1*|*fm-1*) board=fm1;; esac
    if [ -z "$board" ]; then
      read -rp "  Which unit is this firmware for? 1) FM-1   2) SMK-37: " b
      [ "$b" = "2" ] && board=smk37 || board=fm1
    fi
    say "Unit: ${B}$board${N} (from the file's name)"
    say "Type ${B}yes${N} when M-Flasher shows what it will write."
    run m-flasher firmware "$fw" --board "$board" --restart \
      || run sudo m-flasher firmware "$fw" --board "$board" --restart \
      && { ok "Firmware written."
           say "${B}If the screen stays dark: switch the unit off, wait 2 seconds, switch it on.${N} (The SMK-37 does not always"
           say "restart by itself after the loader: that is normal.) It should show the logo, then the help."; } \
      || err "Flashing failed: menu 7 for the log."
    pause; return
  fi
  # the unit runs: flashing goes over MIDI (fm1_install.py)
  [ -f "$WORK/fm1ports.py" ] || curl -fsSL "${INSTALLER_URL%/*}/fm1ports.py" -o "$WORK/fm1ports.py" 2>>"$LOG"
  [ -f "$WORK/fm1_install.py" ] || curl -fsSL "$INSTALLER_URL" -o "$WORK/fm1_install.py" 2>>"$LOG"
  local fw; fw="$(find_firmware)"
  [ -n "$fw" ] || { err "No .fwsc firmware: menu 9 to choose it."; pause; return; }
  say "Firmware: ${B}$fw${N}"
  run "$VENV/bin/python" "$WORK/fm1_install.py" --port midi --info \
    || { err "Neither in UBOOT mode nor over MIDI: menu 4 (key), then come back."; pause; return; }
  read -rp "  The unit is seen above. Flash it? [y/N] " c
  [[ "$c" == "y" || "$c" == "Y" ]] || { warn "Cancelled."; pause; return; }
  run "$VENV/bin/python" "$WORK/fm1_install.py" --port midi --force --no-resources "$fw" \
    && ok "Flash done: the unit restarts." || err "The flash failed: menu 7 for the log."
  pause
}

# ------------------------------------------------ 10. choose the firmware -------------------------------------------
choose_fw() {
  title "Choose the firmware to flash"
  local n; n=$(local_fwsc | grep -c .)
  say "  ${B}1${N}  The .fwsc next to the script or in the folder above (found: $n)"
  say "  ${B}2${N}  A custom .fwsc: a path on this Pi, or an https://… address"
  say "       e.g. ${C}~/Downloads/openvalive-smk37-elite-0.0.3.fwsc${N}"
  say "       e.g. ${C}$FW_SMK_ELITE${N}"
  say "  ${B}3${N}  The official OpenVALive firmware: SMK-37 Elite / SMK-37 Pro / FM-1"
  read -rp "  Choice [1/2/3]: " c
  case "$c" in
    1) if [ "$n" = "1" ]; then FIRMWARE="$(local_fwsc)"; ok "Chosen: $FIRMWARE"
       elif [ "$n" = "0" ]; then err "No .fwsc in $HERE nor in the folder above."
       else
         local i=1; while read -r f; do say "     $i) $f"; i=$((i + 1)); done < <(local_fwsc)
         read -rp "  Which one? " k
         FIRMWARE="$(local_fwsc | sed -n "${k}p")"
         [ -n "$FIRMWARE" ] && ok "Chosen: $FIRMWARE" || err "Not a valid choice."
       fi ;;
    2) read -rp "  Path or address: " src
       src="${src/#\~/$HOME}"
       if [ -f "$src" ]; then FIRMWARE="$src"; ok "Chosen: $FIRMWARE"
       elif [[ "$src" == http* ]]; then
         local out="$WORK/$(basename "${src%%\?*}")"
         run curl -fL "$src" -o "$out" && { FIRMWARE="$out"; ok "Downloaded and chosen: $out"; } || err "Download failed."
       else err "Neither a file nor an address: $src"; fi ;;
    3) read -rp "  1) SMK-37 Elite   2) SMK-37 Pro   3) FM-1: " m
       local url="$FW_SMK_ELITE"; [ "$m" = "2" ] && url="$FW_SMK_PRO"; [ "$m" = "3" ] && url="$FW_FM1"
       local out="$WORK/$(basename "$url")"
       run curl -fL "$url" -o "$out" && { FIRMWARE="$out"; ok "Downloaded and chosen: $out"; } \
         || err "Download failed (Internet?)." ;;
  esac
  case "$FIRMWARE" in *pro*) warn "PRO package: an ELITE keyboard refuses it (and the other way round).";; esac
  pause
}

# ------------------------------------------------ menu --------------------------------------------------------------
while true; do
  title "menu   ($(pi_model))"
  cat <<EOF
  ${B}1${N}  The steps, in order (start here)
  ${B}2${N}  Wiring Pi 4 / Pi 5, wire colours, multimeter check
  ${B}3${N}  Install the tools (Python, GPIO, jl-uboot-tool, M-Flasher, MIDI flasher)
  ${B}4${N}  Send the USB_KEY, then switch the unit on (UBOOT mode)
  ${B}5${N}  Is the keyboard seen? (lsusb / dmesg)
  ${B}6${N}  BACK UP the whole flash (dump) — before any write
  ${B}7${N}  Log: show and save the diagnostics
  ${B}8${N}  Key settings (swap D+/D-, slower, longer)
  ${B}9${N}  Choose the firmware: next to the script / custom / official OpenVALive
  ${B}10${N} Flash: M-Flasher in UBOOT mode, or over MIDI if the unit runs
  ${B}0${N}  Quit

  This session's log: ${C}$LOG${N}
EOF
  read -rp "  Your choice: " choice
  echo "[menu] $choice" >>"$LOG"
  case "$choice" in
    1) steps ;; 2) wiring ;; 3) install_all ;; 4) send_key ;; 5) check_usb ;;
    6) dump_flash ;; 7) journal ;; 8) settings ;; 9) choose_fw ;; 10) reflash ;; 0) say "Bye."; exit 0 ;;
    *) ;;
  esac
done
