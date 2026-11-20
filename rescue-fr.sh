#!/usr/bin/env bash
# =====================================================================================================================
#  M-VAVE SMK-37 / FM-1 : sauvetage d'un appareil qui ne démarre plus (puce JieLi, mode usine « UBOOT »)
#  Sans ouvrir l'appareil : la « clé USB » JieLi passe par le câble USB, depuis le GPIO d'un Raspberry Pi.
#
#  POUR LE LANCER (sur un Raspberry Pi 4 ou 5, Raspberry Pi OS ou Ubuntu), dans le dossier du script :
#      chmod +x rescue-fr.sh
#      ./rescue-fr.sh
#
#  Ce que fait ce script, par le menu :
#    - installe ce qu'il faut (Python, GPIO, outils USB, MIDI) et clone jl-uboot-tool
#    - rappelle le câblage (Pi 4 et Pi 5) avec les couleurs du câble USB
#    - envoie la « clé USB » JieLi (0x16EF) par le GPIO pour forcer la puce en mode UBOOT
#    - vérifie si le clavier est vu (lsusb / dmesg), sauvegarde la flash (dump), garde un journal
#    - reflashe : en mode UBOOT avec M-Flasher (interface graphique), ou en MIDI si l'appareil tourne encore
#
#  Rien n'est écrit dans le clavier sans que tu le demandes. Tout ce qui s'affiche est aussi gardé dans le journal.
# =====================================================================================================================

# ------------------------------------------------ réglages (modifiables ici ou en variables d'environnement) -------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HERE/rescue-work}"                    # tout ce que le script crée va ici
FIRMWARE="${FIRMWARE:-}"                              # un .fwsc précis (sinon : menu 9 pour le choisir)
FW_SMK_ELITE="${FW_SMK_ELITE:-https://github.com/Tom-Rfid/OpenVALive_SMK-37/releases/download/preview-dev/openvalive-smk37-elite-0.0.3.fwsc}"
FW_SMK_PRO="${FW_SMK_PRO:-https://github.com/Tom-Rfid/OpenVALive_SMK-37/releases/download/preview-dev/openvalive-smk37-pro-0.0.3.fwsc}"
FW_FM1="${FW_FM1:-https://github.com/Tom-Rfid/OpenVALive_FM-1/releases/download/preview-dev/openvalive-fm1-0.0.3.fwsc}"
INSTALLER_URL="${INSTALLER_URL:-https://github.com/Tom-Rfid/OpenVALive_FM-1/releases/latest/download/fm1_install.py}"
JLTOOL_GIT="${JLTOOL_GIT:-https://github.com/kagaimiq/jl-uboot-tool.git}"
MFLASHER_VERSION="${MFLASHER_VERSION:-0.12.1}"
RESCUE_VERSION="2026-11-20 c"                   # (shown in every title: which script is running)
DUMP_SIZE="${DUMP_SIZE:-0x100000}"                    # taille de la flash à sauvegarder (1 Mo sur le SMK-37 Elite)
KEY_SECONDS="${KEY_SECONDS:-6}"                       # durée d'envoi de la clé
KEY_HALF_US="${KEY_HALF_US:-10}"                      # demi-période de l'horloge en µs (10 ≈ 50 kHz ; 25 plus lent)
GPIO_DP="${GPIO_DP:-17}"                              # D+ (horloge)  : GPIO17 = broche physique 11
GPIO_DM="${GPIO_DM:-27}"                              # D- (données)  : GPIO27 = broche physique 13
KEY_SOURCE="${KEY_SOURCE:-gpio}"                      # gpio : ce Raspberry Pi envoie la clé ; pico : un Pico (RP2040) l'envoie

VENV="$WORK/venv"
LOGDIR="$WORK/journaux"
DUMPDIR="$WORK/sauvegardes"
LOG="$LOGDIR/session-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$WORK" "$LOGDIR" "$DUMPDIR"

# ------------------------------------------------ affichage ---------------------------------------------------------
B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; M=$'\e[35m'; W=$'\e[37m'; BL=$'\e[94m'; N=$'\e[0m'
say()  { echo -e "$*" | tee -a "$LOG"; }
ok()   { say "${G}✔ $*${N}"; }
warn() { say "${Y}⚠ $*${N}"; }
err()  { say "${R}✖ $*${N}"; }
pause(){ echo; read -rp "  Entrée pour revenir au menu… " _; }
run()  { say "${C}\$ $*${N}"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
title(){ clear; say "${B}${M}══════════════════════════════════════════════════════════════${N}";
         say "${B}  SMK-37 / FM-1 — sauvetage   ·   $*   ${N}${C}(script $RESCUE_VERSION)${N}";
         say "${B}${M}══════════════════════════════════════════════════════════════${N}"; }

pi_model() { tr -d '\0' </proc/device-tree/model 2>/dev/null || echo "inconnu"; }

# ------------------------------------------------ 1. les étapes -----------------------------------------------------
steps() {
  title "Les étapes, dans l'ordre"
  cat <<EOF | tee -a "$LOG"

  ${B}1.${N} Menu ${B}3${N} : installer les outils (une seule fois, il faut Internet).
  ${B}2.${N} Menu ${B}2${N} : faire le câblage (Pi ÉTEINT pendant que tu branches les fils GPIO).
  ${B}3.${N} Menu ${B}4${N} : interrupteur de l'appareil sur ${B}OFF${N}, Entrée, ${B}PUIS${N} interrupteur sur ${B}ON${N} pendant les ${KEY_SECONDS} s.
       (Allumé avant Entrée, il démarre normalement en MIDI : le script le dit, recommence.)
  ${B}4.${N} Menu ${B}5${N} : vérifier. On cherche un appareil ${B}4c4a${N} (JieLi en mode UBOOT). ${B}Écran noir : normal${N} dans ce mode.
       Rien ? Recommence l'étape 3 (allume plus tôt / plus tard), puis essaie le menu ${B}8${N} (plus lent,
       ou D+/D- inversés).
  ${B}5.${N} Menu ${B}6${N} : ${B}SAUVEGARDE de toute la flash${N} (dump). On n'écrit RIEN avant d'avoir ce fichier.
  ${B}6.${N} Garde le dump en lieu sûr (clé USB) et le journal (menu ${B}7${N}) : c'est ce qu'il faut pour analyser
       et réparer, sans toucher à la calibration du clavier ni au Bluetooth.
  ${B}7.${N} Menu ${B}9${N} : choisir le firmware (tant qu'il y a Internet, n'importe quand).
  ${B}8.${N} Menu ${B}10${N} : en mode UBOOT, ${B}1${N} flashe directement le firmware choisi avec M-Flasher en ligne de commande
       (tu tapes ${B}yes${N}), ${B}2${N} ouvre sa fenêtre ; si l'appareil tourne encore, il flashe en MIDI.
  ${B}9.${N} ${B}Éteins l'appareil, attends 2 s, rallume-le${N} : le logo, puis l'aide. (Il reste noir sinon.)

  Le journal de cette session : ${C}$LOG${N}
EOF
  pause
}

# ------------------------------------------------ 2. câblage --------------------------------------------------------
wiring() {
  title "Câblage — $(pi_model)"
  cat <<EOF | tee -a "$LOG"

  ${B}Le câble :${N} un câble USB-A → USB-C (le côté USB-C va dans le SMK-37 ou le FM-1). Deux façons :
   ${B}a)${N} sans couper : ouvre la gaine au milieu, dénude 5 mm sur le noir, le vert et le blanc, et soude-y
      directement la résistance et le fil vers le Pi. ${Y}Isole chaque soudure (gaine, scotch) : rien ne doit se toucher.${N}
   ${B}b)${N} en coupant : coupe au milieu, réunis les fils couleur avec couleur (soudure ou Wago 3 entrées),
      la 3e entrée sert au fil vers le Pi.
  ${Y}Le bout USB-A reste dans un port USB du Pi : après la clé, c'est le Pi qui doit voir la puce en USB.${N}
  (à l'écran : ${BL}bleu${N} = le fil blanc du câble, pour le distinguer)

     bout USB-A (port USB du Pi)                bout USB-C (appareil)
       ${R}rouge 5V ════════════════════════════════════ rouge${N}      ← ${R}${B}JAMAIS vers le GPIO${N}
       ${W}noir GND ═════════════════╦══════════════════ noir${N}
                                 ${W}║${N}
                                 ${W}╚══════════════════════════════→ broche 9  (GND)${N}
       ${G}vert D+  ═════════════════╦══════════════════ vert${N}
                                 ${G}║${N}
                                 ${G}╚═══[ 100 Ω ]══════════════════→ broche 11 (GPIO${GPIO_DP})  ★ D+${N}
       ${BL}blanc D- ═════════════════╦══════════════════ blanc${N}
                                 ${BL}║${N}
                                 ${BL}╚═══[ 100 Ω ]══════════════════→ broche 13 (GPIO${GPIO_DM})  ★ D-${N}

  ${B}Raspberry Pi 5 (et Pi 4) — connecteur 40 broches, VUE DE DESSUS${N}
  carte posée, connecteur en haut à gauche, connecteur du ventilateur à sa droite, la puce en dessous :

    ┌─────────────────────────────────────────────────────────────── bord du HAUT de la carte
    │    2    4    6    8   10   12   14   16   18   20  …  40
    │   [5V] [5V] [GND][TX] [RX] [G18][GND][G23][G24][GND] …        [ventilateur]
    │   [3V3][G2] [G3] [G4] [${W}GND${N}][${G}G17${N}][${BL}G27${N}][G22][3V3][G10] …
    │    1    3    5    7    9   11   13   15   17   19  …  39
    │                        ${W}▲${N}    ${G}▲${N}    ${BL}▲${N}
    │                       ${W}noir${N} ${G}D+ ★${N} ${BL}D- ★${N}
    │                       ${W}GND${N}  ${G}vert${N} ${BL}blanc${N}
    │                    (rangée intérieure, côté puce)
    bord GAUCHE de la carte

    En partant de la gauche, sur la rangée du BAS (côté puce) : 5e trou = ${W}noir${N}, 6e = ${G}vert D+${N}, 7e = ${BL}blanc D-${N}.

  ${B}Pi 4${N} : même connecteur, même câblage (puce « gpiochip0 »). ${B}Pi 5${N} : puce RP1, le script la trouve seul.

  ${B}Vérifier au multimètre (mode bip), câble débranché :${N}
     fiche USB-A face à toi, languette plastique en bas, contacts en haut, de gauche à droite :
        [1] 5 V rouge   [2] D- blanc   [3] D+ vert   [4] GND noir    (1 et 4 sont plus longs)
     (avant de couper) contact 3 ↔ fil vert, contact 2 ↔ fil blanc, contact 4 ↔ fil noir : ça bipe.
     Et AUCUN fil ne doit biper avec un autre (pas de court-circuit).
EOF
  pause
}

# ------------------------------------------------ M-FLASHER ---------------------------------------------------------
install_mflasher() {
  title "Installation de M-Flasher ${MFLASHER_VERSION}"

  local arch deb url
  arch="$(dpkg --print-architecture)"           # arm64 (Raspberry Pi) ou amd64 (PC)
  deb="$WORK/m-flasher_${MFLASHER_VERSION}-1_${arch}.deb"
  url="https://github.com/jvitkauskas/m-flasher/releases/download/v${MFLASHER_VERSION}/m-flasher_${MFLASHER_VERSION}-1_${arch}.deb"

  say "Téléchargement de M-Flasher ${MFLASHER_VERSION}..."

  if ! curl -fL "$url" -o "$deb"; then
    err "Téléchargement impossible."
    pause
    return 1
  fi

  say "Installation du paquet Debian..."

  if ! run sudo apt-get install -y "$deb"; then
    err "Installation de M-Flasher échouée."
    pause
    return 1
  fi

  if command -v m-flasher >/dev/null 2>&1; then
    ok "M-Flasher installé : $(command -v m-flasher)"
  else
    err "Installation terminée, mais commande m-flasher introuvable."
  fi

  pause
}

# ------------------------------------------------ 3. installation ---------------------------------------------------
install_all() {
  title "Installation des outils"
  run sudo apt-get update
  run sudo apt-get install -y git python3 python3-pip python3-venv python3-dev build-essential \
      usbutils libusb-1.0-0 libasound2-dev curl unzip python3-lgpio sg3-utils pkg-config cmake libjack-jackd2-dev \
    || warn "Une partie des paquets n'a pas pu s'installer (voir ci-dessus)."
  install_mflasher
  if [ ! -d "$VENV" ]; then run python3 -m venv --system-site-packages "$VENV"; fi
  run "$VENV/bin/pip" install --upgrade pip
  run "$VENV/bin/pip" install mido python-rtmidi pyusb pyserial
  "$VENV/bin/python" -c "import lgpio" 2>/dev/null || run "$VENV/bin/pip" install lgpio \
    || warn "lgpio introuvable : sudo apt install python3-lgpio"
  if [ -d "$WORK/jl-uboot-tool/.git" ]; then run git -C "$WORK/jl-uboot-tool" pull
  else run git clone "$JLTOOL_GIT" "$WORK/jl-uboot-tool"; fi
  if [ -f "$WORK/jl-uboot-tool/requirements.txt" ]; then
    run "$VENV/bin/pip" install -r "$WORK/jl-uboot-tool/requirements.txt"
  fi
  run curl -fsSL "${INSTALLER_URL%/*}/fm1ports.py" -o "$WORK/fm1ports.py"          # (fm1_install.py needs it)
  run curl -fsSL "$INSTALLER_URL" -o "$WORK/fm1_install.py" || warn "fm1_install.py non téléchargé."
  write_key_script
  ok "Installation terminée. Journal : $LOG"
  pause
}

# ------------------------------------------------ la clé USB_KEY (Python, écrite par le script) ---------------------
write_key_script() {
  cat >"$WORK/cle_usb.py" <<'PY'
# Envoie la clé JieLi USB_KEY 0x16EF : D+ = horloge (lue au front montant), D- = données, bit de poids fort d'abord.
import lgpio, sys, time
DP, DM, SECONDS, HALF_US = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4])
KEY = 0x16EF

def find_chip():                       # Pi 5 : la RP1 ; Pi 4 : la bcm2711 ; sinon gpiochip0
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
print(f"puce GPIO : gpiochip{chip} ({label})   D+ = GPIO{DP}   D- = GPIO{DM}   {SECONDS:.0f} s   demi-période {HALF_US} µs")
h = lgpio.gpiochip_open(chip)
lgpio.gpio_claim_output(h, DP, 1)
lgpio.gpio_claim_output(h, DM, 1)

def wait(us):
    end = time.perf_counter_ns() + us * 1000
    while time.perf_counter_ns() < end:
        pass

print(">>> METS L'INTERRUPTEUR DE L'APPAREIL SUR ON MAINTENANT <<<", flush=True)
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
    lgpio.gpio_claim_input(h, DP)      # lignes relâchées : la puce prend l'USB
    lgpio.gpio_claim_input(h, DM)
    lgpio.gpiochip_close(h)
print(f"{packets} clés envoyées. Lignes relâchées.")
PY
}

send_key() {
  if [ "$KEY_SOURCE" = "pico" ]; then          # la clé vient d'un Raspberry Pi Pico : ici, on ne fait que regarder
    title "Clé USB_KEY envoyée par le Pico (RP2040)"
    say "Le Pico (rp2040/usb_key.py) : GP6 = D+ (vert), GP7 = D- (blanc), GND = noir. Le bout USB-A dans CET ordinateur."
    say "1. Interrupteur de l'appareil sur ${B}OFF${N}.   2. Lance usb_key.py sur le Pico (Thonny : Run)."
    say "3. Pendant ses 6 s, interrupteur sur ${B}ON${N}.   4. Reviens ici et appuie sur Entrée."
    read -rp "  Entrée quand c'est fait… " _
    check_usb noPause
    pause; return
  fi
  title "Envoi de la clé USB_KEY"
  [ -f "$WORK/cle_usb.py" ] || write_key_script
  say "${B}Avant :${N} l'${B}interrupteur de l'appareil sur OFF${N}, le câble USB dans le Pi, les 3 fils GPIO en place."
  say "${B}Ensuite :${N} tu appuies sur Entrée, le Pi envoie la clé pendant ${KEY_SECONDS} s, et ${B}PENDANT ce temps${N}"
  say "          tu mets l'${B}interrupteur du clavier sur ON${N} (idéalement 1 seconde après Entrée)."
  say "          La puce lit la clé au moment où elle s'allume : allumée avant, ou après les ${KEY_SECONDS} s, ça ne marche pas."
  say "${R}${B}⚠ L'ORDRE COMPTE :${N} ${B}1. ÉTEINS l'appareil${N}   ${B}2. Entrée ici${N}   ${B}3. ALLUME-le${N} pendant que la clé part."
  say "   Allumé avant d'appuyer sur Entrée, il démarre normalement (en MIDI) et la clé ne sert à rien."
  read -rp "  L'appareil est ÉTEINT ? [o/N] " off
  case "$off" in o|O|y|Y) ;; *) warn "Éteins-le d'abord, puis relance le menu 4."; pause; return ;; esac
  read -rp "  Entrée pour lancer la clé, PUIS allume l'appareil… " _
  sudo dmesg -C 2>/dev/null
  run sudo "$VENV/bin/python" "$WORK/cle_usb.py" "$GPIO_DP" "$GPIO_DM" "$KEY_SECONDS" "$KEY_HALF_US" \
    || err "Le script de clé a échoué (lgpio installé ? menu 3)."
  wait_device
  check_usb noPause
  pause
}

# l'état USB de l'appareil : uboot (4c4a, la puce en mode chargeur), normal (son firmware tourne : MIDI), none
NORMAL_IDS="3654:7756|1209:0001|smk|fm-1|m-vave|sinco|openvalive"
usb_state() {
  if lsusb | grep -qi "4c4a:"; then echo uboot
  elif lsusb | grep -qiE "$NORMAL_IDS"; then echo normal
  else echo none; fi
}
normal_name() { lsusb | grep -iE "$NORMAL_IDS" | head -n 1 | cut -d' ' -f6-; }
# après la clé : quelques secondes pour que la puce apparaisse ; rien du tout : on refait énumérer l'USB une fois
wait_device() {
  for _ in 1 2 3 4 5 6; do [ "$(usb_state)" = none ] || return 0; sleep 1; done
  say "Rien encore : l'USB du Pi est relancé une fois pour revoir les appareils…"
  for a in /sys/bus/usb/devices/usb*/authorized; do echo 0 | sudo tee "$a" >/dev/null; echo 1 | sudo tee "$a" >/dev/null; done
  for _ in 1 2 3 4; do [ "$(usb_state)" = none ] || return 0; sleep 1; done
}

# ------------------------------------------------ 5. détection ------------------------------------------------------
check_usb() {
  [ "$1" = "noPause" ] || title "Le clavier est-il vu ?"
  say "${B}lsusb :${N}"; run lsusb
  say "${B}dmesg (dernières lignes USB) :${N}"; sudo dmesg | grep -iE "usb|4c4a|jieli|uboot|scsi|sd[a-z]|midi" | tail -n 25 | tee -a "$LOG"
  case "$(usb_state)" in
    uboot)
      ok "Appareil JieLi 4c4a trouvé : la puce est en mode UBOOT. Étape suivante : menu 6 (sauvegarde)."
      say "   ${B}L'écran de l'appareil reste noir dans ce mode : c'est normal.${N} Rien n'est cassé ; il en sort quand on l'éteint."
      lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN | tee -a "$LOG"
      warn "Ne monte et ne formate PAS le disque qu'Ubuntu pourrait proposer." ;;
    normal)
      err "L'appareil a DÉMARRÉ NORMALEMENT ($(normal_name)) : il tourne en MIDI, pas en mode UBOOT."
      say "   Il était allumé avant la clé (ou trop tard). ${B}Éteins-le, relance le menu 4, Entrée, PUIS allume-le.${N}"
      say "   (La sauvegarde, menu 6, ne passe qu'en mode UBOOT. Pour juste reflasher un appareil qui démarre : menu 10, en MIDI.)" ;;
    *)
      warn "Rien de vu sur l'USB. Si l'appareil est allumé et l'écran reste noir, la puce a peut-être pris la clé :"
      say "   relance le menu 5 dans quelques secondes. Sinon recommence le menu 4 (allume un peu plus tôt ou plus tard), ou menu 8 (réglages)." ;;
  esac
  [ "$1" = "noPause" ] || pause
}

# ------------------------------------------------ 6. sauvegarde -----------------------------------------------------
dump_flash() {
  title "Sauvegarde de toute la flash (dump)"
  [ -d "$WORK/jl-uboot-tool" ] || { err "jl-uboot-tool absent : menu 3 d'abord."; pause; return; }
  case "$(usb_state)" in
    uboot) ;;
    normal) err "L'appareil tourne normalement en MIDI ($(normal_name)) : la sauvegarde ne passe qu'en mode UBOOT (4c4a)."
            say "   Éteins-le, menu 4, Entrée, PUIS allume-le ; le menu 5 doit montrer 4c4a."; pause; return ;;
    *) warn "Pas d'appareil 4c4a vu : la sauvegarde va sûrement échouer (menu 4)." ;;
  esac
  local out="$DUMPDIR/flash-$(date +%Y%m%d-%H%M%S).bin"
  say "Taille demandée : ${B}$DUMP_SIZE${N} (modifiable : DUMP_SIZE=0x400000 ./rescue-fr.sh)"
  say "1) automatique : le script envoie « read 0 $DUMP_SIZE … » puis « exit » à l'outil"
  say "2) à la main    : tu tapes toi-même dans l'outil (affiche d'abord la taille de la flash)"
  read -rp "  Choix [1/2] : " c
  cd "$WORK/jl-uboot-tool" || return
  if [ "$c" = "2" ]; then
    say "Dans l'outil, tape :   ${B}read 0 $DUMP_SIZE $out${N}   puis   ${B}exit${N}"
    sudo "$VENV/bin/python" jluboottool.py 2>&1 | tee -a "$LOG"
  else
    printf 'read 0 %s %s\nexit\n' "$DUMP_SIZE" "$out" | sudo "$VENV/bin/python" jluboottool.py 2>&1 | tee -a "$LOG"
  fi
  cd "$HERE" || return
  if [ -s "$out" ]; then
    sudo chown "$(id -u):$(id -g)" "$out" 2>/dev/null
    ok "Sauvegarde : $out ($(stat -c %s "$out") octets)"
    say "L'appareil reste en mode UBOOT (écran noir) : menu 9 puis 10 pour écrire un firmware, ou éteins-le pour en sortir."
    sha256sum "$out" | tee -a "$LOG" | tee "$out.sha256" >/dev/null
    cp "$out" "$out.copie" && ok "Une copie de sécurité : $out.copie (mets-en une aussi sur une clé USB)"
  else
    err "Pas de fichier de sauvegarde. Regarde le message de l'outil ci-dessus (menu 7 pour le journal)."
    warn "Si l'outil ne reconnaît pas la puce (AC791N), garde le journal et n'essaie rien d'autre."
  fi
  pause
}

# ------------------------------------------------ 7. journal --------------------------------------------------------
journal() {
  title "Journal et diagnostic"
  local f="$LOGDIR/diagnostic-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "=== $(date)   $(pi_model)   $(uname -a)"
    echo "=== lsusb";  lsusb
    echo "=== lsusb -t"; lsusb -t
    echo "=== lsblk"; lsblk -o NAME,SIZE,VENDOR,MODEL,TRAN
    echo "=== dmesg (150 dernières lignes)"; sudo dmesg | tail -n 150
    echo "=== aconnect -l (MIDI)"; aconnect -l 2>&1
    echo "=== journal de la session ($LOG)"; cat "$LOG"
  } >"$f" 2>&1
  less -R "$f"
  ok "Diagnostic enregistré : $f   (le fichier à joindre pour demander de l'aide)"
  pause
}

# ------------------------------------------------ 8. réglages de la clé ---------------------------------------------
settings() {
  title "Réglages de l'envoi de la clé"
  say "Actuel : D+ = GPIO$GPIO_DP   D- = GPIO$GPIO_DM   durée ${KEY_SECONDS} s   demi-période ${KEY_HALF_US} µs"
  say "  1) inverser D+ et D-        2) plus lent (25 µs)        3) plus rapide (5 µs)"
  say "  4) durée 10 s               5) revenir aux valeurs de départ"
  say "  6) la clé vient de ce Raspberry Pi (GPIO) / d'un Pico (RP2040) : maintenant ${KEY_SOURCE}"
  read -rp "  Choix : " c
  case "$c" in
    1) t=$GPIO_DP; GPIO_DP=$GPIO_DM; GPIO_DM=$t ;;
    2) KEY_HALF_US=25 ;;
    3) KEY_HALF_US=5 ;;
    4) KEY_SECONDS=10 ;;
    5) GPIO_DP=17; GPIO_DM=27; KEY_SECONDS=6; KEY_HALF_US=10 ;;
    6) [ "$KEY_SOURCE" = "pico" ] && KEY_SOURCE=gpio || KEY_SOURCE=pico ;;
  esac
  ok "Maintenant : D+ = GPIO$GPIO_DP   D- = GPIO$GPIO_DM   ${KEY_SECONDS} s   ${KEY_HALF_US} µs"
  pause
}

# ------------------------------------------------ 9. reflash OpenVALive -----------------------------------------------
# les .fwsc posés à côté du script ou dans le dossier au-dessus (le dossier du firmware dézippé)
local_fwsc() { ls "$HERE"/*.fwsc "$HERE"/../*.fwsc 2>/dev/null | while read -r f; do readlink -f "$f"; done | sort -u; }
find_firmware() {
  if [ -n "$FIRMWARE" ] && [ -f "$FIRMWARE" ]; then echo "$FIRMWARE"; return; fi
  local n; n=$(local_fwsc | grep -c .)
  [ "$n" = "1" ] && local_fwsc
}

# ------------------------------------------------ 9. reflasher ------------------------------------------------------
reflash() {
  title "Reflasher le firmware"
  if lsusb | grep -qi "4c4a:"; then             # mode UBOOT : M-Flasher (protocole USB/SCSI JieLi)
    ok "Appareil en mode UBOOT ($(lsusb | grep -i 4c4a: | head -n 1 | cut -d' ' -f6-))"
    command -v m-flasher >/dev/null 2>&1 || install_mflasher || return
    sudo modprobe sg 2>/dev/null                  # (le pilote SCSI générique qu'il utilise)
    local fw; fw="$(find_firmware)"
    [ -n "$fw" ] || { warn "Pas encore de firmware choisi : menu 9 d'abord."; choose_fw; fw="$(find_firmware)"; title "Reflasher le firmware"; }
    say "Firmware : ${B}${fw:-aucun}${N}"
    say "Le flash passe par ${B}M-Flasher${N}. Il sauvegarde d'abord toute la flash (AUTO BACKUP), ne touche ni au chargeur"
    say "de démarrage, ni à la calibration (C1), ni aux appairages (7B), puis redémarre l'appareil."
    say "  ${B}1${N}  Flasher ${B}ici${N}, directement avec ce firmware (M-Flasher en ligne de commande) — conseillé"
    say "  ${B}2${N}  Ouvrir la fenêtre de M-Flasher (FIRMWARE FILE > CHOOSE FILE, FLASH FIRMWARE, REVIEW & FLASH)"
    read -rp "  Choix [1/2] : " c
    if [ "$c" = "2" ]; then
      run m-flasher
      say "${B}Après le flash : éteins l'appareil, attends 2 secondes, rallume-le${N} (l'écran reste noir sinon)."
      pause; return
    fi
    [ -n "$fw" ] || { err "Aucun firmware : menu 9."; pause; return; }
    local board=""                              # (le nom du fichier, pas le dossier où il est)
    case "$(basename "$fw" | tr 'A-Z' 'a-z')" in *smk37*|*smk-37*) board=smk37;; *fm1*|*fm-1*) board=fm1;; esac
    if [ -z "$board" ]; then
      read -rp "  Pour quel appareil est ce firmware ? 1) FM-1   2) SMK-37 : " b
      [ "$b" = "2" ] && board=smk37 || board=fm1
    fi
    say "Appareil : ${B}$board${N} (d'après le nom du fichier)"
    say "Tape ${B}yes${N} quand M-Flasher montre ce qu'il va écrire."
    run m-flasher firmware "$fw" --board "$board" --restart \
      || run sudo m-flasher firmware "$fw" --board "$board" --restart \
      && { ok "Firmware écrit."
           say "${B}Si l'écran reste noir : éteins l'appareil, attends 2 secondes, rallume-le.${N} (Le SMK-37 ne redémarre pas"
           say "toujours seul après le chargeur : c'est normal.) Il doit montrer le logo, puis l'aide."; } \
      || err "Le flash a échoué : menu 7 pour le journal."
    pause; return
  fi
  # l'appareil tourne : le flash passe par le MIDI (fm1_install.py)
  [ -f "$WORK/fm1ports.py" ] || curl -fsSL "${INSTALLER_URL%/*}/fm1ports.py" -o "$WORK/fm1ports.py" 2>>"$LOG"
  [ -f "$WORK/fm1_install.py" ] || curl -fsSL "$INSTALLER_URL" -o "$WORK/fm1_install.py" 2>>"$LOG"
  local fw; fw="$(find_firmware)"
  [ -n "$fw" ] || { err "Aucun firmware .fwsc : menu 9 pour le choisir."; pause; return; }
  say "Firmware : ${B}$fw${N}"
  run "$VENV/bin/python" "$WORK/fm1_install.py" --port midi --info \
    || { err "Ni en mode UBOOT, ni en MIDI : menu 4 (clé), puis reviens ici."; pause; return; }
  read -rp "  L'appareil est vu ci-dessus. Lancer le flash ? [o/N] " c
  [[ "$c" == "o" || "$c" == "O" ]] || { warn "Annulé."; pause; return; }
  run "$VENV/bin/python" "$WORK/fm1_install.py" --port midi --force --no-resources "$fw" \
    && ok "Flash terminé : l'appareil redémarre." || err "Le flash a échoué : menu 7 pour le journal."
  pause
}

# ------------------------------------------------ 10. choisir le firmware -------------------------------------------
choose_fw() {
  title "Choisir le firmware à flasher"
  local n; n=$(local_fwsc | grep -c .)
  say "  ${B}1${N}  Le .fwsc posé à côté du script ou dans le dossier au-dessus (trouvés : $n)"
  say "  ${B}2${N}  Un .fwsc personnalisé : un chemin sur ce Pi, ou une adresse https://…"
  say "       ex. ${C}~/Téléchargements/openvalive-smk37-elite-0.0.3.fwsc${N}"
  say "       ex. ${C}$FW_SMK_ELITE${N}"
  say "  ${B}3${N}  Le firmware OpenVALive officiel : SMK-37 Elite / SMK-37 Pro / FM-1"
  read -rp "  Choix [1/2/3] : " c
  case "$c" in
    1) if [ "$n" = "1" ]; then FIRMWARE="$(local_fwsc)"; ok "Choisi : $FIRMWARE"
       elif [ "$n" = "0" ]; then err "Aucun .fwsc dans $HERE ni dans le dossier au-dessus."
       else
         local i=1; while read -r f; do say "     $i) $f"; i=$((i + 1)); done < <(local_fwsc)
         read -rp "  Lequel ? " k
         FIRMWARE="$(local_fwsc | sed -n "${k}p")"
         [ -n "$FIRMWARE" ] && ok "Choisi : $FIRMWARE" || err "Choix invalide."
       fi ;;
    2) read -rp "  Chemin ou adresse : " src
       src="${src/#\~/$HOME}"
       if [ -f "$src" ]; then FIRMWARE="$src"; ok "Choisi : $FIRMWARE"
       elif [[ "$src" == http* ]]; then
         local out="$WORK/$(basename "${src%%\?*}")"
         run curl -fL "$src" -o "$out" && { FIRMWARE="$out"; ok "Téléchargé et choisi : $out"; } || err "Téléchargement impossible."
       else err "Ni un fichier, ni une adresse : $src"; fi ;;
    3) read -rp "  1) SMK-37 Elite   2) SMK-37 Pro   3) FM-1 : " m
       local url="$FW_SMK_ELITE"; [ "$m" = "2" ] && url="$FW_SMK_PRO"; [ "$m" = "3" ] && url="$FW_FM1"
       local out="$WORK/$(basename "$url")"
       run curl -fL "$url" -o "$out" && { FIRMWARE="$out"; ok "Téléchargé et choisi : $out"; } \
         || err "Téléchargement impossible (Internet ?)." ;;
  esac
  case "$FIRMWARE" in *pro*) warn "Paquet PRO : un clavier ELITE le refusera (et inversement).";; esac
  pause
}

# ------------------------------------------------ menu --------------------------------------------------------------
while true; do
  title "menu   ($(pi_model))"
  cat <<EOF
  ${B}1${N}  Les étapes, dans l'ordre (commence ici)
  ${B}2${N}  Câblage Pi 4 / Pi 5 et couleurs des fils, test au multimètre
  ${B}3${N}  Installer les outils (Python, GPIO, jl-uboot-tool, M-Flasher, flasheur MIDI)
  ${B}4${N}  Envoyer la clé USB_KEY puis allumer l'appareil (mode UBOOT)
  ${B}5${N}  Le clavier est-il vu ? (lsusb / dmesg)
  ${B}6${N}  SAUVEGARDER toute la flash (dump)  — avant toute écriture
  ${B}7${N}  Journal : afficher et enregistrer le diagnostic
  ${B}8${N}  Réglages de la clé (inverser D+/D-, plus lent, plus long)
  ${B}9${N}  Choisir le firmware : à côté du script / personnalisé / officiel OpenVALive
  ${B}10${N} Reflasher : M-Flasher en mode UBOOT, ou en MIDI si l'appareil tourne
  ${B}0${N}  Quitter

  Journal de cette session : ${C}$LOG${N}
EOF
  read -rp "  Ton choix : " choice
  echo "[menu] $choice" >>"$LOG"
  case "$choice" in
    1) steps ;; 2) wiring ;; 3) install_all ;; 4) send_key ;; 5) check_usb ;;
    6) dump_flash ;; 7) journal ;; 8) settings ;; 9) choose_fw ;; 10) reflash ;; 0) say "Au revoir."; exit 0 ;;
    *) ;;
  esac
done