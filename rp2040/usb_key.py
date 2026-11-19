# M-VAVE SMK-37 / FM-1 — the JieLi "USB key" from a Raspberry Pi Pico (RP2040), MicroPython.  UNTESTED.
# Same idea as menu 4 of rescue-*.sh (set the key source to "pico" there: menu 8, option 6), for those without a Raspberry Pi 4/5: GP6 = D+ (clock), GP7 = D- (data),
# GND to the cable's black wire. The cable's USB-A end goes into a computer (Linux: M-Flasher, or the scripts).
# Run it (Thonny: Run), then switch the unit ON within the 6 seconds. Then look for a 4c4a device (lsusb).
from machine import Pin
import time

KEY = 0x16EF                   # sent most significant bit first; the chip reads D- on each rising edge of D+
SECONDS = 6
HALF_US = 10                   # ~50 kHz; try 25 if nothing is seen

dp = Pin(6, Pin.OUT, value=1)
dm = Pin(7, Pin.OUT, value=1)

def send_key():
    for i in range(15, -1, -1):
        dm.value((KEY >> i) & 1)
        dp.value(0); time.sleep_us(HALF_US)
        dp.value(1); time.sleep_us(HALF_US)

print(">>> SWITCH THE UNIT ON NOW / ALLUME L'APPAREIL MAINTENANT <<<")
t0 = time.ticks_ms()
n = 0
while time.ticks_diff(time.ticks_ms(), t0) < SECONDS * 1000:
    send_key()
    n += 1
    time.sleep_us(4 * HALF_US)
Pin(6, Pin.IN); Pin(7, Pin.IN)  # lines released: the chip takes the USB
print(n, "keys sent; lines released / clés envoyées, lignes relâchées")
