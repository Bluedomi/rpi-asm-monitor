# Raspberry Pi ARM64 Temperature & System Monitor (Assembly)

Un moniteur système minimaliste, ultra‑rapide et entièrement écrit en **assembleur ARM64**, sans libc, utilisant uniquement des **syscalls Linux**.  
Affiche en temps réel :

- 🕒 l’heure UTC (format `[HH:MM:SS UTC]`, en cyan)
- 🌡️ la température CPU (lecture directe de `/sys/class/thermal/...`, en jaune)
- ⚡ l’état électrique du SoC :  
  - `[OK]` en vert  
  - `[UNDERVOLT]` en rouge  
- 🚀 la fréquence CPU actuelle (lecture de `scaling_cur_freq`, en bleu)

Le tout avec des couleurs ANSI, un format compact, et un rafraîchissement toutes les 2 secondes.

---

## ✨ Fonctionnalités

### 🔹 Horodatage UTC
- Lecture via `clock_gettime(CLOCK_REALTIME)`
- Conversion HH:MM:SS sans libc
- Affichage en cyan

### 🔹 Température CPU
- Lecture de `/sys/class/thermal/thermal_zone0/temp`
- Conversion complète millidegrés → degrés + dixième
- Affichage en jaune

### 🔹 Détection de sous‑tension (under‑voltage)
- Lecture de `/sys/devices/platform/soc/soc:firmware/get_throttled`
- Parsing hexadécimal → entier
- Test du bit 0 (under‑voltage)
- Affichage :
  - `[OK]` en vert
  - `[UNDERVOLT]` en rouge

### 🔹 Fréquence CPU
- Lecture de `scaling_cur_freq`
- Conversion kHz → MHz (avec une décimale)
- Affichage en bleu

---

## 🛠️ Compilation

Assembler et lier statiquement :

```bash
as -o monitor_temp.o monitor_temp.s
gcc -nostdlib -static -o monitor-temp-ASM monitor_temp.o
strip monitor-temp-ASM
