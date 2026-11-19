# The USB key from a Raspberry Pi Pico (RP2040) — untested

For those without a Raspberry Pi 4/5. The Pico only sends the key; any computer running Linux (or the rescue script
with `KEY_SOURCE=pico`) is the USB host that then sees the chip and runs M-Flasher.

```
   USB-A end (computer)                      USB-C end (unit)
     red   5V  ════════════════════════════════ red        ← never to the Pico
     black GND ══════════╦═════════════════════ black ──→ Pico GND (pin 38)
     green D+  ══════════╬═════════════════════ green ──→ [100 Ω] → Pico GP6 (pin 9)
     white D-  ══════════╬═════════════════════ white ──→ [100 Ω] → Pico GP7 (pin 10)
```

1. Install MicroPython on the Pico, open `usb_key.py` in Thonny.
2. The unit's switch OFF, its cable in the computer.
3. Run the script, then switch the unit ON within the 6 seconds.
4. `lsusb`: a `4c4a:` device means the chip is in UBOOT mode. Nothing? Run it again, switch on earlier or later,
   try `HALF_US = 25`, or swap GP6 and GP7.

Please report what works (an issue on the repository): Pico model, unit, settings.

**FR** — Le Pico envoie seulement la clé ; un ordinateur sous Linux (ou le script avec `KEY_SOURCE=pico`) reste l'hôte
USB qui voit ensuite la puce et lance M-Flasher. Câblage ci-dessus (vert → GP6, blanc → GP7, noir → GND, jamais le
rouge). Pas encore testé : merci de faire un retour.
