# 🧩 Raspberry Pi ARM64 System Monitor — Pure Assembly (AArch64)

Un moniteur système complet, écrit **entièrement en assembleur ARMv8‑A (AArch64)**, sans libc, sans dépendances, utilisant uniquement les **syscalls Linux**.  
Ce projet a été conçu **dans un but didactique**, pour explorer l’assembleur ARM64 sur Raspberry Pi 4B — et il a évolué en un véritable tableau de bord système en temps réel.

---

## ✨ Fonctionnalités principales

Le programme affiche en continu :

### 🕒 Horodatage UTC
- Lecture via `clock_gettime(CLOCK_REALTIME)`
- Conversion HH:MM:SS sans libc
- Affichage en cyan

### 🌡️ Température CPU
- Lecture directe du SoC : `/sys/class/thermal/thermal_zone0/temp`
- Conversion millidegrés → degrés + dixième
- Couleur dynamique :
  - vert < 50°C  
  - jaune < 65°C  
  - orange < 80°C  
  - rouge ≥ 80°C  
- Emoji thermomètre (optionnel)

### 🚀 Fréquence CPU
- Lecture : `/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq`
- Conversion kHz → MHz (avec décimale)
- Couleur dynamique selon la fréquence

### ⚡ État électrique (under‑voltage)
- Lecture : `/sys/devices/platform/soc/soc:firmware/get_throttled`
- Parsing hexadécimal → entier
- Bit 0 = sous‑tension
- Affichage :
  - `⚡️❌` en rouge (under‑voltage)
  - `⚡️✅` en vert (OK)

### 🧮 Charge CPU (instantanée)
- Lecture : `/proc/stat`
- Calcul du pourcentage CPU utilisé depuis l’intervalle précédent
- Couleur dynamique :
  - vert < 25%
  - jaune < 50%
  - orange < 75%
  - rouge ≥ 75%

### 📊 Load averages (1m, 5m, 15m)
- Lecture : `/proc/loadavg`
- Extraction des trois valeurs
- Affichage coloré

### 🧠 RAM utilisée (%)
- Lecture : `/proc/meminfo`
- Parsing de `MemTotal` et `MemAvailable`
- Calcul du pourcentage utilisé
- Couleur dynamique :
  - vert < 50%
  - jaune < 80%
  - rouge ≥ 80%

---

## 🎥 Vidéos de présentation

Deux vidéos illustrent l’évolution du projet, depuis la version initiale (0.0) jusqu’à la version avancée (1.9).  
Elles montrent la progression pédagogique du moniteur système en assembleur ARM64 sur Raspberry Pi 4B.

---

### 🔹 Version 0.0 — Première ébauche (lecture simple de la température)

[![Demo v0.0](https://img.youtube.com/vi/9T2jM_kBt7g/0.jpg)](https://youtu.be/9T2jM_kBt7g)

➡️ https://youtu.be/9T2jM_kBt7g

Cette version montre :
- la lecture brute de la température CPU via `/sys/class/thermal/...`
- la conversion millidegrés → degrés
- un affichage minimaliste sans couleurs
- la structure de base du programme en assembleur AArch64

---

### 🔹 Version 1.9 — Moniteur système complet (température, fréquence, RAM, CPU, loadavg…)

[![Demo v1.9](https://img.youtube.com/vi/Y2lfMdMY5QY/0.jpg)](https://youtu.be/Y2lfMdMY5QY)

➡️ https://youtu.be/Y2lfMdMY5QY

Cette version inclut :
- température CPU avec couleur dynamique  
- fréquence CPU (MHz + dixième)  
- charge CPU instantanée (%)  
- load averages (1m, 5m, 15m)  
- RAM utilisée (%)  
- état électrique (under‑voltage)  
- horodatage UTC  
- couleurs ANSI  
- rafraîchissement 1 Hz  
- parsing complet de `/proc` et `/sys`  

---
## 📸 Captures d’écran

Voici un aperçu du moniteur système ARM64 en action, exécuté sur un Raspberry Pi 4B via un terminal Termux sur smartphone (connexion SSH).

<p align="center">
  <img src="docs/screenshots/termux_raspi4b_v1.9.jpg" width="480">
</p>

<p align="center"><em>Affichage en temps réel : température, fréquence CPU, charge, RAM, load average et état électrique.</em></p>

---

## 🎧 Fichiers audio explicatifs

- `audio_RPi4b_AArch64_Assembly_System_Monitor_v0.0_mono.m4a`  
- `audio_RPi4b_AArch64_Assembly_System_Monitor_v1.9_mono.m4a`

Les fichiers audio (versions mono) sont disponibles dans : docs/audio
Ils commentent la démarche pédagogique et l’évolution du projet.

---

## 🕰️ Historique des versions

### **Version 0.0**
- Lecture de la température CPU  
- Conversion millidegrés → degrés  
- Affichage minimaliste  
- Syscalls utilisés : openat, read, write, close  
- Base du projet, première exploration de l’assembleur ARM64  

### **Version 1.9**
- Température CPU (couleurs dynamiques + emoji)  
- Fréquence CPU (MHz + dixième, couleurs dynamiques)  
- Charge CPU instantanée (%) via `/proc/stat`  
- RAM utilisée (%) via `/proc/meminfo`  
- Load averages (1m, 5m, 15m)  
- Détection under‑voltage (⚡️❌ / ⚡️✅)  
- Horodatage UTC  
- Couleurs ANSI  
- Rafraîchissement 1 Hz  
- Parsing complet de `/proc` et `/sys`  
- Code structuré, modulaire, lisible  

---

## 🧱 Architecture du programme

Le programme suit une boucle simple :

1. Lire température  
2. Lire throttling  
3. Lire fréquence CPU  
4. Lire loadavg  
5. Lire /proc/stat et calculer CPU%  
6. Lire /proc/meminfo et calculer RAM%  
7. Lire l’heure UTC  
8. Formater et colorer chaque section  
9. Afficher la ligne complète  
10. Pause 1 seconde  

Aucune allocation dynamique.  
Aucun appel à libc.  
Aucun binaire externe.  
Uniquement des **syscalls Linux ARM64**.

---

## 🔧 Syscalls utilisés

| Fonction | Syscall | Description |
|---------|---------|-------------|
| `openat` | 56 | Ouvrir un fichier dans `/sys` ou `/proc` |
| `read` | 63 | Lire les données |
| `close` | 57 | Fermer le fichier |
| `write` | 64 | Affichage |
| `clock_gettime` | 113 | Heure UTC |
| `nanosleep` | 101 | Pause |
| `exit` | 93 | Quitter |

---

## 🛠️ Compilation

Assembler et lier statiquement :

```bash
as -o monitor_temp.o monitor_temp.s
gcc -nostdlib -static -o monitor-temp-ASM monitor_temp.o
strip monitor-temp-ASM
```

---

## ▶️ Exécution

```bash
./monitor-temp-ASM
```

## Exemple de sortie

```bash
[20:09:08 UTC] 🌡️ 34.5°C F:600.0 MHz L:0% M:20% ⚡️✅ 1m:0.00 5m:0.00 15m:0.00
```

## 🎯 Objectif pédagogique

Ce projet a été conçu pour :

- me faire découvrir l’assembleur ARM64  
- comprendre les syscalls Linux  
- manipuler `/proc` et `/sys`  
- apprendre les conversions numériques sans libc  
- structurer un programme assembleur complexe  
- progresser version après version  
- documenter l’évolution avec vidéos et audios  

Il n’a aucune prétention de performance ou de production — seulement le plaisir d’apprendre et d’expérimenter.

---
