# jieli-usbkey-unbrick

**Ramener à la vie un appareil à puce JieLi qui ne démarre plus — sans l'ouvrir.**
Fait d'abord pour les M-VAVE **SMK-37** et **FM-1**.

> 🇬🇧 [Read in English](README.md) · 🌐 **La page illustrée : <https://tom-rfid.github.io/jieli-usbkey-unbrick/#fr>**

Un firmware qui plante au démarrage rend l'appareil invisible en USB : plus de port MIDI, les outils du fabricant ne le
voient pas, les boutons au démarrage ne font rien. À l'intérieur, la puce JieLi garde dans sa ROM un **chargeur USB
d'usine** (« UBOOT »). Ce dépôt l'ouvre depuis un Raspberry Pi, par le câble USB de l'appareil, puis sauvegarde et
réécrit le firmware avec [M-Flasher](https://github.com/jvitkauskas/m-flasher).

| | |
|---|---|
| ✅ **Testé** | M-VAVE SMK-37 Elite, Raspberry Pi 5 — clé, sauvegarde de 1 Mo, firmware écrit, appareil revenu (novembre 2026) |
| 🔶 **Devrait marcher, pas encore testé** | M-VAVE FM-1 (même famille JieLi, géré par M-Flasher), SMK-37 Pro, Raspberry Pi 4 |
| 🧪 **Préparé, pas testé** | la clé depuis un Raspberry Pi Pico (RP2040) : [`rp2040/`](rp2040/README.md) |

## Le principe

Au moment où elle s'allume, la ROM de la puce guette un motif particulier sur ses lignes USB : la **clé USB**. Si
elle le voit, elle lance son chargeur USB au lieu du firmware. La clé est le nombre de 16 bits **`0x16EF`**, envoyé
bit de poids fort en premier, avec **D+ comme horloge** et **D− pour les données** : la puce lit D− à chaque **front
montant de D+**.

```
  0x16EF  =  0001 0110 1110 1111   (bit de poids fort d'abord)

  D+ (horloge) ‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾ …   environ 50 kHz
                    ↑     ↑     ↑     ↑     ↑     ↑     ↑     ↑        la puce lit D- à chaque front montant
  D- (données)      0     0     0     1     0     1     1     0  …     posé pendant que D+ est bas, un bit par coup
```

1. L'appareil est **éteint** ; le Raspberry Pi envoie la clé en boucle (6 secondes).
2. Tu **allumes l'appareil** : sa ROM attrape la clé et répond en tirant les deux lignes au niveau bas 1 à 2 ms.
3. Le script **relâche les lignes** (elles passent en entrée) : la puce lance son chargeur USB, et le Raspberry Pi —
   l'hôte USB au bout du même câble — voit un nouvel appareil : **`4c4a:8057` `WL80UBOOT1.00`**.
4. **M-Flasher** lit toute la flash (toujours une sauvegarde d'abord), puis écrit le firmware (`.fwsc`) sans toucher
   au **chargeur de démarrage**, à la **calibration des touches** ni aux **appairages Bluetooth**.

Linux ne donne pas une précision à la microseconde, mais ce n'est pas nécessaire : la puce suit l'horloge, pas une
vitesse fixe.

## Le câblage

Il faut un Raspberry Pi 4 ou 5, un câble USB-A → USB-C **de données**, trois fils (deux résistances de 100 Ω si tu en
as) et un multimètre pour une vérification. Le bout USB-A **reste dans le Raspberry Pi** : après la clé, c'est lui
l'hôte qui voit la puce.

```
   bout USB-A (port USB du Raspberry Pi)          bout USB-C (l'appareil)
     rouge 5V  ════════════════════════════════════ rouge      ← JAMAIS vers le GPIO (le 5 V le détruit)
     noir  GND ════════════════╦═══════════════════ noir
                               ╚════════════════════════════→ broche 9  (GND)
     vert  D+  ════════════════╦═══════════════════ vert
                               ╚═══[ 100 Ω ]════════════════→ broche 11 (GPIO17)  ★ D+ horloge
     blanc D-  ════════════════╦═══════════════════ blanc
                               ╚═══[ 100 Ω ]════════════════→ broche 13 (GPIO27)  ★ D- données
```

Ouvre la gaine du câble au milieu et ajoute les trois fils **sans couper** (soudure, puis isole chaque point), ou coupe
et réunis les couleurs avec des Wago à 3 entrées, la troisième allant vers le Pi.

```
   Raspberry Pi 4 / 5 — connecteur 40 broches, vue de dessus (connecteur en haut, broche 1 à gauche)
   ┌──────────────────────────────────────────────────────────── bord du haut de la carte
   │    2    4    6    8   10   12   14   16 …
   │   [5V] [5V] [GND][TX] [RX] [G18][GND][G23] …
   │   [3V3][G2] [G3] [G4] [GND][G17][G27][G22] …
   │    1    3    5    7    9   11   13   15 …
   │                        ▲    ▲    ▲
   │                       noir  D+   D-        (rangée intérieure, 5e, 6e et 7e trous en partant de la gauche)
```

**Vérifie avant de couper**, multimètre en mode bip, câble débranché — fiche USB-A face à toi, languette en plastique
en bas : `[1] 5 V rouge · [2] D− blanc · [3] D+ vert · [4] GND noir`. Contact 3 ↔ vert, 2 ↔ blanc, 4 ↔ noir doivent
biper ; aucun fil ne doit biper avec un autre. Certains câbles bon marché ont d'autres couleurs : fie-toi au bip, pas
à la couleur.

## Utilisation

```bash
chmod +x rescue-fr.sh
./rescue-fr.sh            # en anglais : ./rescue-en.sh
```

| Menu | Quoi |
|---|---|
| 1 | les étapes, dans l'ordre (commence ici) |
| 2 | le câblage à l'écran, Pi 4 / Pi 5 |
| 3 | tout installer (Python, GPIO, jl-uboot-tool, M-Flasher, outils MIDI) |
| 4 | envoyer la clé : appareil **éteint**, Entrée, puis **allumé** dans les 6 s |
| 5 | l'appareil est-il vu ? (`lsusb`, `dmesg` : on cherche `4c4a`) |
| 6 | **sauvegarder toute la flash** — avant toute écriture |
| 7 | journal et diagnostic, enregistrés dans un fichier texte |
| 8 | réglages de la clé : inverser D+/D−, plus lent, plus long, **clé envoyée par un Pico** |
| 9 | choisir le firmware : le `.fwsc` à côté du script, un personnalisé (chemin ou adresse), ou un officiel |
| 10 | flasher : M-Flasher en mode UBOOT, ou en MIDI si l'appareil tourne encore |

Rien de vu à l'étape 5 ? Allume un peu plus tôt ou plus tard, puis essaie le menu 8 (horloge plus lente, ou D+ et D−
inversés).

## Bon à savoir

- **Garde ta sauvegarde** (sur une clé USB aussi). Ne restaure jamais la sauvegarde d'un autre appareil sur le tien :
  la calibration des touches est propre à chaque appareil.
- La clé passe par le câble : **pas besoin d'ouvrir l'appareil**. Sur ces cartes, la flash est dans le boîtier de la
  puce JieLi : il n'y a de toute façon pas de puce flash à court-circuiter.
- Les firmwares (`.fwsc`) sont propres à chaque modèle : un SMK-37 Elite refuse un paquet Pro, et inversement.

## Merci

- [kagaimiq / jielie](https://kagaimiq.github.io/jielie/isp/usb/usb-key.html) — la clé USB, documentée.
- [jvitkauskas / m-flasher](https://github.com/jvitkauskas/m-flasher) — l'outil de flash du FM-1 et du SMK-37.
- [kagaimiq / jl-uboot-tool](https://github.com/kagaimiq/jl-uboot-tool) — le protocole UBOOT.

Fait en ramenant un SMK-37 d'un mauvais firmware, pour [OpenVALive](https://github.com/Tom-Rfid/OpenVALive_SMK-37).
Sans lien avec M-VAVE ni JieLi. À tes risques. Licence : MIT.
