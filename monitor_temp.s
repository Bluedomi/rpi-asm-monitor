/*
 * ==================================================================
 * Fichier     : monitor_temp.s
 * Version     : 2.7
 * Date        : 2026-03-25
 * Auteur      : /B4SH 😎
 * ------------------------------------------------------------------
 * LANGAGE     : ASSEMBLEUR AArch64 (ARMv8-A)
 * DESCRIPTION : Monitoring système temps réel pour Raspberry Pi 4B
 *
 * Nouveautés v2.7 :
 *   - Séparation claire des sections .data et .rodata.
 *   - Ajout d’un message d’en‑tête enrichi (version, auteur, date
 *     et heure de compilation via __DATE__ / __TIME__).
 *   - Passage à la compilation via gcc + préprocesseur C, tout en
 *     conservant l’extension historique .s du projet.
 *   - Possibilité d’injecter des constantes (#define, -D…) pour
 *     gérer version, auteur, options de build, etc.
 *   - Introduction d’un mécanisme propre et purement assembleur
 *     pour activer ou désactiver l’usage du syscall pread64 :
 *
 *         .equ SYS_PREAD64, -1   → pread64 non utilisé
 *         .equ SYS_PREAD64, 67   → pread64 activé
 *
 *     Lorsque SYS_PREAD64 = 67, le code utilise pread64 (1 seul
 *     syscall, plus optimal). Dans le cas contraire, le programme
 *     bascule automatiquement vers le fallback lseek + read (2
 *     syscalls).
 *
 * Optimisations du calcul de température CPU :
 *   - Code générique pour toute valeur de TEMP_MAX.
 *   - Optimisation spécifique lorsque TEMP_MAX = 80 :
 *       → calcul du pourcentage sans division (temp + temp>>2).
 *   - Optimisation maximale activable via :
 *         .equ MAX80_ULTRA_OPTIMIZED, 1
 *     permettant d’exploiter pleinement le cas TEMP_MAX = 80.
 *   - Pour toute autre valeur, bascule automatique vers la version
 *     générique (division classique).
 *
 * ------------------------------------------------------------------
 * ⚠️  Ancienne méthode de compilation des versions précédentes,
 *     rappelée uniquement pour mémoire :
 *
 *   $ as -o monitor_temp.o monitor_temp.s
 *   $ gcc -nostdlib -static -o monitor-temp-ASM monitor_temp.o
 *   $ strip monitor-temp-ASM
 *
 * Cette méthode NE FONCTIONNE PLUS avec ce fichier source, car :
 *   - le code utilise désormais le préprocesseur C (#define, __DATE__,
 *     __TIME__, concaténation de chaînes…),
 *   - l’assembleur pur `as` ne reconnaît pas ces directives.
 *
 * ------------------------------------------------------------------
 * ✔️  Méthode de compilation recommandée
 *     gcc + préprocesseur C + strip agressif 🗜
 *
 *   Compilation minimale (strip intégré au linkage) :
 *
 *     $ gcc -x assembler-with-cpp -nostdlib -static \
 *           -Wl,--strip-all \
 *           monitor_temp.s -o monitor-temp-ASM
 *
 *   Variante équivalente (strip externe maximal) :
 *
 *     $ gcc -x assembler-with-cpp -nostdlib -static monitor_temp.s \
 *           -o monitor-temp-ASM
 *     $ strip --strip-all --remove-section=.comment \
 *             --remove-section=.note* \
 *             monitor-temp-ASM
 *
 * Ces deux méthodes produisent un binaire minimal (~5.8 kB),
 * idéal pour un outil système léger et autonome.
 *
 * L’option -x assembler-with-cpp force l’utilisation du préprocesseur
 * C même si le fichier conserve l’extension .s, garantissant ainsi la
 * compatibilité avec les versions précédentes du repository.
 *
 * ==================================================================
 */

#define RELEASE "2.7"
#define AUTHOR "Dominique, aka /B4SH 😎"

.global _start

// ---------------------------------------------------------------
// Options de compilation
// ---------------------------------------------------------------
.equ SHOW_FREQ,             1
.equ SHOW_THERMO,           1
.equ MAX80_ULTRA_OPTIMIZED, 1

// ---------------------------------------------------------------
// Normalisation de la température en pourcentage
// ---------------------------------------------------------------
// La température brute est convertie en % via TEMP_MAX, puis
// transmise à pct_to_color (même logique que CPU/RAM).
//
// Le code est générique : TEMP_MAX peut être ajusté librement.
// Lorsque TEMP_MAX = 80, une routine optimisée est utilisée
// (pas de udiv). Pour d’autres valeurs, le code bascule
// automatiquement sur la version générique.
//
// Une optimisation maximale peut être activée via :
//     .equ MAX80_ULTRA_OPTIMIZED, 1
// Active l’optimisation maximale spécifique au cas TEMP_MAX = 80.
//
// 🔥 85°C = seuil officiel de throttling du SoC Raspberry Pi 4B.
// Au‑delà, le firmware réduit automatiquement la fréquence CPU.
// Références :
//   https://raspberrytips.com/raspberry-pi-temperature
//   https://www.raspberrypi.com/products/raspberry-pi-4-model-b/specifications/
//
// TEMP_MAX définit le seuil interne de normalisation.
// 80°C = zone critique → affichage rouge clignotant.
// ---------------------------------------------------------------
.equ TEMP_MAX,              80      // °C

// ---------------------------------------------------------------
// Tailles de buffers
// ---------------------------------------------------------------
.equ BUFFER_SIZE,           16
.equ BUFFER_FREQ_SIZE,      16
.equ BUFFER_THR_SIZE,       16
.equ BUFFER_LOAD_SIZE,      64
.equ BUFFER_STAT_SIZE,      128
.equ BUFFER_MEMINFO_SIZE,   256
.equ OUTPUT_BUFFER_SIZE,    512

// ---------------------------------------------------------------
// Largeurs de colonnes (en caractères visibles)
// ---------------------------------------------------------------
.equ COL_TEMP_WIDTH,        6       // "103.7°C"
.equ COL_FREQ_WIDTH,        8       // "F:2400.0"
.equ COL_CPU_WIDTH,         7       // "L:100%"
.equ COL_RAM_WIDTH,         7       // "M:100%"
.equ COL_UV_WIDTH,          4       // "⚡️❌"
.equ COL_LA_WIDTH,          8       // "1m:12.35"

// ---------------------------------------------------------------
// Syscalls
// ---------------------------------------------------------------
.equ SYS_OPENAT,            56
.equ SYS_READ,              63
.equ SYS_WRITE,             64
.equ SYS_CLOSE,             57
.equ SYS_LSEEK,             62
.equ SYS_NANOSLEEP,         101
.equ SYS_EXIT,              93
.equ SYS_CLOCK_GETTIME,     113
.equ SYS_PREAD64,           67 // ou -1 pour éviter syscall PREAD64

.equ AT_FDCWD,              -100
.equ SEEK_SET,              0
.equ STDOUT,                1

// ---------------------------------------------------------------
// Indices des fd persistants (dans fd_table)
// ---------------------------------------------------------------
.equ FD_IDX_TEMP,           0
.equ FD_IDX_THROTTLED,      1
.equ FD_IDX_FREQ,           2
.equ FD_IDX_LOADAVG,        3
.equ FD_IDX_STAT,           4
.equ FD_IDX_MEMINFO,        5
.equ FD_COUNT,              6

.section .rodata

// Message d'en-tête
header_text:        .ascii "\n\033[1;36mmonitor-temp-ASM\033[1;32m v" RELEASE"\n"                       
                    .ascii "\033[1;34mBuild on: " __DATE__ " at " __TIME__ "\n"
                    .ascii "Author: " AUTHOR "\n"
                    .ascii "Real-time performance monitor for the Raspberry Pi 4B,\n"
                    .ascii "written entirely in ARMv8‑A assembly (Linux userland).\033[0m\n"
                    .ascii "Metrics:\n🌡 Temp | F: CPU Frequency | L: CPU% | M: RAM% | ⚡ Under-voltage | Load Averages\n"
                    .asciz  "\033[1;31mPress Ctrl‑C to terminate.\n\n"

// .ascii "\n\033[1;36mmonitor-temp-ASM\033[1;32m v"RELEASE\033[0m\n"

// Codes couleur ANSI - Version "Vivid"
str_cyan:           .asciz "\033[1;36m"
str_blue:           .asciz "\033[1;34m"
str_green:          .asciz "\033[1;32m"
str_red:            .asciz "\033[1;31m"
str_reset:          .asciz "\033[0m"

.equ str_color_1m,   str_blue
.equ str_color_5m,   str_blue
.equ str_color_15m,  str_blue

// Labels des métriques
str_freq:           .asciz "F:"
str_load:           .asciz "L:"
str_ram:            .asciz "M:"
str_mhz:            .asciz "MHz"
str_thermo:         .asciz "🌡 "
str_celsius:        .asciz "°C"
str_ok:             .asciz "⚡️✅"
str_undervolt:      .asciz "⚡️❌"
str_space:          .asciz " "
str_percent:        .asciz "%"
str_1m:             .asciz "1m:"
str_5m:             .asciz "5m:"
str_15m:            .asciz "15m:"
str_utc:            .asciz " UTC]"
str_na:             .asciz "--"

// ---------------------------------------------------------------
// Palette de couleurs dégradé vert→rouge (13 entrées, index 0-12)
// Utilisée par pct_to_color ET select_cpu_color.
//
// Sémantique unifiée :
//   index 0  = 0%   = OK / froid / idle   → vert électrique
//   index 6  = 50%  = attention            → jaune brillant
//   index 12 = 100% = critique / surchauffe → rouge clignotant
//
// Pour la fréquence CPU :  index = (freq - 600) * 100 / 1200 * 12 / 100
// Pour la température    :  index = temp * 12 / TEMP_MAX
// Pour CPU% et RAM%      :  index = pct  * 12 / 100
// ---------------------------------------------------------------
str_p000:           .asciz "\033[1;38;5;46m"    // index 0  : vert électrique
str_p008:           .asciz "\033[1;38;5;47m"    // index 1  : vert printemps
str_p016:           .asciz "\033[1;38;5;48m"    // index 2  : vert menthe
str_p025:           .asciz "\033[1;38;5;83m"    // index 3  : vert chartreuse
str_p033:           .asciz "\033[1;38;5;119m"   // index 4  : jaune-vert néon
str_p041:           .asciz "\033[1;38;5;155m"   // index 5  : jaune acide
str_p050:           .asciz "\033[1;38;5;191m"   // index 6  : jaune brillant
str_p058:           .asciz "\033[1;38;5;226m"   // index 7  : jaune d'or
str_p066:           .asciz "\033[1;38;5;214m"   // index 8  : orange vif
str_p075:           .asciz "\033[1;38;5;208m"   // index 9  : orange pur
str_p083:           .asciz "\033[1;38;5;202m"   // index 10 : orange-rouge
str_p091:           .asciz "\033[1;38;5;196m"   // index 11 : rouge vif
str_p100:           .asciz "\033[1;5;38;5;196m" // index 12 : rouge clignotant

// Table indexée 0-12 : un pointeur par palier (~8% de la plage)
    .align 3
cpu_color_table:
        .quad   str_p000        // index 0
        .quad   str_p008        // index 1
        .quad   str_p016        // index 2
        .quad   str_p025        // index 3
        .quad   str_p033        // index 4
        .quad   str_p041        // index 5
        .quad   str_p050        // index 6
        .quad   str_p058        // index 7
        .quad   str_p066        // index 8
        .quad   str_p075        // index 9
        .quad   str_p083        // index 10
        .quad   str_p091        // index 11
        .quad   str_p100        // index 12

// Chemins des fichiers système
filepath_temp:      .asciz "/sys/class/thermal/thermal_zone0/temp"
filepath_throttled: .asciz "/sys/devices/platform/soc/soc:firmware/get_throttled"
filepath_freq:      .asciz "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
filepath_loadavg:   .asciz "/proc/loadavg"
filepath_stat:      .asciz "/proc/stat"
filepath_meminfo:   .asciz "/proc/meminfo"

// Needles pour strstr
needle_cpu:         .asciz "cpu "
needle_memtotal:    .asciz "MemTotal:"
needle_memavail:    .asciz "MemAvailable:"

.section .data

// Buffers de lecture
buffer:         .space BUFFER_SIZE
buffer_thr:     .space BUFFER_THR_SIZE
buffer_freq:    .space BUFFER_FREQ_SIZE
buffer_load:    .space BUFFER_LOAD_SIZE
buffer_stat:    .space BUFFER_STAT_SIZE
buffer_meminfo: .space BUFFER_MEMINFO_SIZE

// Buffer de sortie
outbuf:         .space OUTPUT_BUFFER_SIZE

// Nanosleep : 1 seconde
sleep_ts:
    .quad 1
    .quad 0

// clock_gettime
.balign 16
timespec:
    .quad 0
    .quad 0

// Variables pour le calcul différentiel CPU
prev_idle:      .quad 0
prev_total:     .quad 0
first_stat:     .quad 1

// Table des fd persistants (initialisés à -1)
.balign 8
fd_table:
    .quad -1    // FD_IDX_TEMP
    .quad -1    // FD_IDX_THROTTLED
    .quad -1    // FD_IDX_FREQ
    .quad -1    // FD_IDX_LOADAVG
    .quad -1    // FD_IDX_STAT
    .quad -1    // FD_IDX_MEMINFO

// ---------------------------------------------------------------
.section .text
// ---------------------------------------------------------------

// ================================================================
// print_str : écrit une chaîne ASCIIZ sur stdout (fd 1)
// Entrée : x0 = adresse de la chaîne terminée par 0
// Utilise : x1, x2, x8 (registres scratch)
// ================================================================
print_str:
    mov  x1, x0          // pointeur de la chaîne
    mov  x2, #0          // longueur à calculer
.Llen:
    ldrb w3, [x1, x2]    // lire un octet
    cbz  w3, .Lwrite     // fin de chaîne ?
    add  x2, x2, #1      // incrémenter longueur
    b    .Llen
.Lwrite:
    mov  x0, #STDOUT     // 1 = sortie standard
    mov  x8, #SYS_WRITE  // 64 = sys_write
    svc  0
    ret

// ================================================================
// copy_str : copie une chaîne ASCIIZ de x0 vers (x2), met à jour x2
// Préserve x1 (début de champ). Utilise w3 comme scratch.
// ================================================================
copy_str:
    ldrb w3, [x0], #1
    cbz  w3, .Lcs_done
    cmp  x2, x28
    b.ge .Lcs_done
    strb w3, [x2], #1
    b    copy_str
.Lcs_done:
    ret

// ================================================================
// write_byte : écrit un octet w0 dans (x2) si place disponible
// ================================================================
write_byte:
    cmp  x2, x28
    b.ge 1f
    strb w0, [x2], #1
1:  ret

// ================================================================
// open_fd : ouvre un fichier et stocke le fd dans fd_table
// Entrée : x0 = chemin, x1 = index
// ================================================================
open_fd:
    stp  x4, lr, [sp, #-16]!
    mov  x4, x1
    mov  x1, x0
    mov  x0, #AT_FDCWD
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  0
    cmp  x0, #0
    blt  .Lopen_err
    adrp x3, fd_table
    add  x3, x3, :lo12:fd_table
    str  x0, [x3, x4, lsl #3]
.Lopen_err:
    ldp  x4, lr, [sp], #16
    ret

// ================================================================
// read_fd_persistent : lseek(0) + read sur fd persistant
// Entrée : x0 = index fd_table, x1 = buffer, x2 = taille max
// Sortie : x0 = octets lus, ou -1
// ================================================================
read_fd_persistent:
    stp  x4, x5,  [sp, #-32]!
    stp  x6, lr,  [sp, #16]

    mov  x4, x1
    mov  x5, x2
    mov  x6, x0

    adrp x1, fd_table
    add  x1, x1, :lo12:fd_table
    ldr  x3, [x1, x6, lsl #3]
    cmp  x3, #0
    blt  .Lrfp_err

    mov  x0, x3

// ------------------------------------------------------------------
// Configuration du syscall pread64
//   -1  = pread64 indisponible → fallback lseek + read
//   67  = pread64 disponible   → 1 seul syscall
// ------------------------------------------------------------------
.if SYS_PREAD64 != 67
// lseek + read (2 sys call) 👍 ✔️
    mov  x1, #0
    mov  x2, #SEEK_SET
    mov  x8, #SYS_LSEEK
    svc  0

    mov  x0, x3
    mov  x1, x4
    mov  x2, x5
    mov  x8, #SYS_READ
    svc  0
.else
// usage de SYS_PREAD64 plus optimal
// pread 1 seul sys call 🔥 ✅
    mov  x0, x3        // fd
    mov  x1, x4        // buffer
    mov  x2, x5        // size
    mov  x3, #0        // offset
    mov  x8, #SYS_PREAD64
    svc  0
.endif

    cmp  x0, #0
    blt  .Lrfp_err

    mov  x7, x0
    cmp  x7, x5
    b.ge .Lrfp_no_null
    add  x1, x4, x7
    strb wzr, [x1]
.Lrfp_no_null:
    mov  x0, x7
    b    .Lrfp_done
.Lrfp_err:
    mov  x0, #-1
.Lrfp_done:
    ldp  x6, lr,  [sp, #16]
    ldp  x4, x5,  [sp], #32
    ret

// ================================================================
// parse_uint : chaîne décimale → entier 64 bits
// Entrée : x0 = pointeur  |  Sortie : x0 = valeur, x1 = ptr après
// ================================================================
parse_uint:
    mov  x5, #0
    mov  x6, x0
1:
    ldrb w7, [x6], #1
    cmp  w7, #'0'
    blt  2f
    cmp  w7, #'9'
    bgt  2f
    sub  w7, w7, #'0'
    and  x7, x7, #0xFF
    add  x5, x5, x5, lsl #2
    lsl  x5, x5, #1
    add  x5, x5, x7
    b    1b
2:
    sub  x6, x6, #1
    mov  x0, x5
    mov  x1, x6
    ret

// ================================================================
// parse_hex : chaîne hexadécimale → entier 64 bits
// Entrée : x0 = pointeur  |  Sortie : x0 = valeur, x1 = ptr après
// ================================================================
parse_hex:
    mov  x5, #0
    mov  x6, x0
1:
    ldrb w7, [x6], #1
    cmp  w7, #'0'
    blt  2f
    cmp  w7, #'9'
    ble  .Lph_digit
    cmp  w7, #'A'
    blt  2f
    cmp  w7, #'F'
    ble  .Lph_upper
    cmp  w7, #'a'
    blt  2f
    cmp  w7, #'f'
    ble  .Lph_lower
    b    2f
.Lph_digit:
    sub  w7, w7, #'0'
    b    .Lph_store
.Lph_upper:
    sub  w7, w7, #'A'
    add  w7, w7, #10
    b    .Lph_store
.Lph_lower:
    sub  w7, w7, #'a'
    add  w7, w7, #10
.Lph_store:
    and  x7, x7, #0xFF
    lsl  x5, x5, #4
    add  x5, x5, x7
    b    1b
2:
    sub  x6, x6, #1
    mov  x0, x5
    mov  x1, x6
    ret

// ================================================================
// uint_to_str : entier 64 bits → chaîne décimale dans (x2)
// Entrée : x0 = valeur  |  x9 utilisé comme scratch
// ================================================================
uint_to_str:
    sub  sp, sp, #32
    mov  x3, sp
    mov  x4, x0
    mov  x5, #10
    mov  x6, #0

    cbnz x4, 1f
    mov  w9, '0'
    cmp  x2, x28
    b.ge .Luts_end
    strb w9, [x2], #1
    add  sp, sp, #32
    ret
1:
    udiv x7, x4, x5
    msub x9, x7, x5, x4
    add  w9, w9, '0'
    strb w9, [x3, x6]
    add  x6, x6, #1
    mov  x4, x7
    cbnz x4, 1b

    add  x3, x3, x6
    sub  x3, x3, #1
2:
    ldrb w9, [x3], #-1
    cmp  x2, x28
    b.ge .Luts_skip
    strb w9, [x2], #1
.Luts_skip:
    subs x6, x6, #1
    b.ne 2b
.Luts_end:
    add  sp, sp, #32
    ret

// ================================================================
// strstr : recherche needle dans haystack
// Entrée : x0 = haystack, x1 = needle  |  Sortie : x0 = ptr ou 0
// ================================================================
strstr:
    mov  x2, x0
.Lss_outer:
    ldrb w3, [x2]
    cbz  w3, .Lss_notfound
    mov  x4, x2
    mov  x5, x1
.Lss_inner:
    ldrb w6, [x5], #1
    cbz  w6, .Lss_found
    ldrb w7, [x4], #1
    cbz  w7, .Lss_advance
    cmp  w6, w7
    b.ne .Lss_advance
    b    .Lss_inner
.Lss_advance:
    add  x2, x2, #1
    b    .Lss_outer
.Lss_found:
    mov  x0, x2
    ret
.Lss_notfound:
    mov  x0, #0
    ret

// ================================================================
// pad_to_width : padding d'une colonne (ignore ANSI et emojis)
// Entrée : x0 = largeur voulue, x1 = début du champ, x2 = fin
// ================================================================
pad_to_width:
    mov  x3, x1
    mov  x4, #0
.Lptw_scan:
    cmp  x3, x2
    beq  .Lptw_pad
    ldrb w5, [x3]
    cmp  w5, #0x1B
    bne  .Lptw_utf8
    add  x3, x3, #1
    ldrb w6, [x3]
    cmp  w6, #'['
    bne  .Lptw_scan
.Lptw_ansi_skip:
    add  x3, x3, #1
    ldrb w6, [x3]
    cmp  w6, #'m'
    bne  .Lptw_ansi_skip
    add  x3, x3, #1
    b    .Lptw_scan
.Lptw_utf8:
    cmp  w5, #0xF0
    bge  .Lptw_4b
    cmp  w5, #0xE0
    bge  .Lptw_3b
    cmp  w5, #0xC0
    bge  .Lptw_2b
    add  x4, x4, #1
    add  x3, x3, #1
    b    .Lptw_scan
.Lptw_4b:
    add  x4, x4, #2
    add  x3, x3, #4
    b    .Lptw_scan
.Lptw_3b:
    add  x4, x4, #1
    add  x3, x3, #3
    b    .Lptw_scan
.Lptw_2b:
    add  x4, x4, #1
    add  x3, x3, #2
    b    .Lptw_scan
.Lptw_pad:
    cmp  x4, x0
    bge  .Lptw_done
    mov  w5, ' '
.Lptw_fill:
    cmp  x2, x28
    b.ge .Lptw_done
    strb w5, [x2], #1
    add  x4, x4, #1
    cmp  x4, x0
    blt  .Lptw_fill
.Lptw_done:
    ret

// ================================================================
// pct_to_color : pourcentage [0-100] → pointeur couleur ANSI
// ------------------------------------------------------------------
// Mappe linéairement un pourcentage sur les 13 entrées de
// cpu_color_table. index = val * 12 / 100, clampé à [0, 12].
//
// index 0  →  0% : vert (OK / froid / idle)
// index 12 → 100% : rouge clignotant (critique / saturé)
//
// Entrée  : x0 = pourcentage (0-100)
// Sortie  : x0 = pointeur vers chaîne ANSI
// Préserve: x1, x2, x18
// ================================================================
pct_to_color:
    stp  x1, lr, [sp, #-16]!

    // index = val * 12 / 100
    mov  x3, #12
    mul  x9, x0, x3
    mov  x3, #100
    udiv x9, x9, x3

    // clamp : index ∈ [0, 12]
    cmp  x9, #12
    mov  x3, #12
    csel x9, x3, x9, gt

    adrp x3, cpu_color_table
    add  x3, x3, :lo12:cpu_color_table
    ldr  x0, [x3, x9, lsl #3]

    ldp  x1, lr, [sp], #16
    ret

// ================================================================
// select_cpu_color : fréquence MHz (x18) → pointeur couleur ANSI
// ------------------------------------------------------------------
// Convertit la fréquence en pourcentage de la plage [600-1800] MHz
// puis délègue à pct_to_color (tail call).
//
// Plage : 600 MHz → index 0 (vert), 1800 MHz → index 12 (rouge)
//
// Entrée  : x18 = fréquence en MHz
// Sortie  : x0  = pointeur vers chaîne ANSI
// Préserve: x1, x2
// ================================================================
select_cpu_color:
    stp  x1, lr, [sp, #-16]!

    // pct = (freq - 600) * 100 / 1200
    mov  x3, #600
    subs x0, x18, x3               // x0 = freq - 600
    csel x0, xzr, x0, lt           // clamp bas → 0 si freq < 600

    mov  x3, #100
    mul  x0, x0, x3
    mov  x3, #1200
    udiv x0, x0, x3                 // pct ∈ [0, 100]

    ldp  x1, lr, [sp], #16
    b    pct_to_color               // tail call

// ================================================================
// skip_and_copy_nth_word : extrait le (n+1)ème mot d'une chaîne
// Entrée : x0 = buffer, x1 = n mots à sauter, x2 = outbuf courant
// ================================================================
skip_and_copy_nth_word:
    stp  x6, lr, [sp, #-16]!
    mov  x6, x1
    cbz  x6, .Lscnw_copy
.Lscnw_skip_word:
.Lscnw_skip_char:
    ldrb w5, [x0], #1
    cbz  w5, .Lscnw_done
    cmp  w5, #' '
    bne  .Lscnw_skip_char
.Lscnw_skip_spaces:
    ldrb w5, [x0], #1
    cbz  w5, .Lscnw_done
    cmp  w5, #' '
    beq  .Lscnw_skip_spaces
    sub  x0, x0, #1
    subs x6, x6, #1
    bne  .Lscnw_skip_word
.Lscnw_copy:
.Lscnw_copy_char:
    ldrb w4, [x0], #1
    cbz  w4, .Lscnw_done
    cmp  w4, #' '
    beq  .Lscnw_done
    cmp  w4, #'\n'
    beq  .Lscnw_done
    cmp  x2, x28
    b.ge .Lscnw_done
    strb w4, [x2], #1
    b    .Lscnw_copy_char
.Lscnw_done:
    ldp  x6, lr, [sp], #16
    ret

// ================================================================
// open_all_fds : ouvre tous les fichiers au démarrage
// ================================================================
open_all_fds:
    stp  x19, lr, [sp, #-16]!

    adrp x0, filepath_temp
    add  x0, x0, :lo12:filepath_temp
    mov  x1, #FD_IDX_TEMP
    bl   open_fd

    adrp x0, filepath_throttled
    add  x0, x0, :lo12:filepath_throttled
    mov  x1, #FD_IDX_THROTTLED
    bl   open_fd

    adrp x0, filepath_freq
    add  x0, x0, :lo12:filepath_freq
    mov  x1, #FD_IDX_FREQ
    bl   open_fd

    adrp x0, filepath_loadavg
    add  x0, x0, :lo12:filepath_loadavg
    mov  x1, #FD_IDX_LOADAVG
    bl   open_fd

    adrp x0, filepath_stat
    add  x0, x0, :lo12:filepath_stat
    mov  x1, #FD_IDX_STAT
    bl   open_fd

    adrp x0, filepath_meminfo
    add  x0, x0, :lo12:filepath_meminfo
    mov  x1, #FD_IDX_MEMINFO
    bl   open_fd

    ldp  x19, lr, [sp], #16
    ret

// ================================================================
// Programme principal
// ================================================================
_start:

    adrp x0, header_text // affiche les infos du header
    add  x0, x0, :lo12:header_text
    bl   print_str

    bl   open_all_fds

    // x28 = sentinelle outbuf (borne haute, constante tout au long)
    adrp x28, outbuf
    add  x28, x28, :lo12:outbuf
    add  x28, x28, #OUTPUT_BUFFER_SIZE

loop:

    // ============================================================
    // 1. Température CPU  →  x24 = degrés entiers, x25 = dixièmes
    // ============================================================
    mov  x0, #FD_IDX_TEMP
    adrp x1, buffer
    add  x1, x1, :lo12:buffer
    mov  x2, #BUFFER_SIZE
    bl   read_fd_persistent
    cmp  x0, #3
    b.lt loop

    adrp x0, buffer
    add  x0, x0, :lo12:buffer
    bl   parse_uint
    mov  x3, x0                     // milli°C

    mov  x5, #1000
    udiv x6, x3, x5                 // degrés entiers
    msub x7, x6, x5, x3
    mov  x5, #100
    udiv x9, x7, x5                 // dixièmes

    mov  x24, x6
    mov  x25, x9

    // ============================================================
    // 2. Under-voltage  →  x20 : -1=inconnu, 0=OK, 1=undervolt
    // ============================================================
    mov  x20, #-1
    mov  x0, #FD_IDX_THROTTLED
    adrp x1, buffer_thr
    add  x1, x1, :lo12:buffer_thr
    mov  x2, #BUFFER_THR_SIZE
    bl   read_fd_persistent
    cmp  x0, #0
    blt  throttle_done

    adrp x0, buffer_thr
    add  x0, x0, :lo12:buffer_thr
    bl   parse_hex
    ands x13, x0, #1
    b.eq .Lvoltage_ok
    mov  x20, #1
    b    throttle_done
.Lvoltage_ok:
    mov  x20, #0
throttle_done:

    // ============================================================
    // 3. Fréquence CPU  →  x18 = MHz entiers, x21 = dixièmes
    // ============================================================
    mov  x18, #-1
    mov  x0, #FD_IDX_FREQ
    adrp x1, buffer_freq
    add  x1, x1, :lo12:buffer_freq
    mov  x2, #BUFFER_FREQ_SIZE
    bl   read_fd_persistent
    cmp  x0, #0
    blt  freq_done

    adrp x0, buffer_freq
    add  x0, x0, :lo12:buffer_freq
    bl   parse_uint
    mov  x16, x0

    mov  x17, #1000
    udiv x18, x16, x17
    msub x19, x18, x17, x16
    mov  x17, #100
    udiv x21, x19, x17
freq_done:

    // ============================================================
    // 4. Load average  →  x27 : 0=absent, 1=disponible
    // ============================================================
    mov  x27, #0
    mov  x0, #FD_IDX_LOADAVG
    adrp x1, buffer_load
    add  x1, x1, :lo12:buffer_load
    mov  x2, #BUFFER_LOAD_SIZE
    bl   read_fd_persistent
    cmp  x0, #4
    blt  load_done
    mov  x27, #1
load_done:

    // ============================================================
    // 5. Utilisation CPU  →  x22 = % CPU (-1 = premier tour)
    // ============================================================
    mov  x0, #FD_IDX_STAT
    adrp x1, buffer_stat
    add  x1, x1, :lo12:buffer_stat
    mov  x2, #BUFFER_STAT_SIZE
    bl   read_fd_persistent
    cmp  x0, #0
    blt  skip_cpu_stat

    adrp x0, buffer_stat
    add  x0, x0, :lo12:buffer_stat
    adrp x1, needle_cpu
    add  x1, x1, :lo12:needle_cpu
    bl   strstr
    cbz  x0, skip_cpu_stat

    add  x1, x0, #4

.Lskip_spaces_stat:
    ldrb w2, [x1], #1
    cmp  w2, #' '
    b.eq .Lskip_spaces_stat
    sub  x1, x1, #1

    sub  sp, sp, #64
    mov  x4, sp
    mov  x2, #0
parse_stat_numbers:
    mov  x0, x1
    bl   parse_uint
    str  x0, [x4, x2, lsl #3]
    add  x2, x2, #1
    cmp  x2, #8
    b.ge stat_done
.Lskip_to_next_stat:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq .Lskip_to_next_stat
    cmp  w5, #'\n'
    b.eq stat_done
    cbz  w5, stat_done
    sub  x1, x1, #1
    b    parse_stat_numbers
stat_done:
    ldr  x3,  [sp, #0 ]
    ldr  x4,  [sp, #8 ]
    ldr  x5,  [sp, #16]
    ldr  x6,  [sp, #24]            // idle
    ldr  x7,  [sp, #32]
    ldr  x9,  [sp, #40]
    ldr  x10, [sp, #48]
    ldr  x11, [sp, #56]
    add  sp, sp, #64

    add  x11, x3,  x4
    add  x11, x11, x5
    add  x11, x11, x6
    add  x11, x11, x7
    add  x11, x11, x9
    add  x11, x11, x10

    adrp x0, first_stat
    add  x0, x0, :lo12:first_stat
    ldr  x1, [x0]
    cmp  x1, #1
    b.eq store_first_stat

    adrp x0, prev_idle
    add  x0, x0, :lo12:prev_idle
    ldr  x12, [x0]
    adrp x0, prev_total
    add  x0, x0, :lo12:prev_total
    ldr  x13, [x0]

    sub  x14, x6,  x12
    sub  x15, x11, x13
    cbz  x15, cpu_stat_done
    sub  x16, x15, x14
    mov  x17, #100
    mul  x16, x16, x17
    udiv x22, x16, x15

    adrp x0, prev_idle
    add  x0, x0, :lo12:prev_idle
    str  x6,  [x0]
    adrp x0, prev_total
    add  x0, x0, :lo12:prev_total
    str  x11, [x0]
    adrp x0, first_stat
    add  x0, x0, :lo12:first_stat
    str  xzr, [x0]
    b    cpu_stat_done

store_first_stat:
    adrp x0, prev_idle
    add  x0, x0, :lo12:prev_idle
    str  x6,  [x0]
    adrp x0, prev_total
    add  x0, x0, :lo12:prev_total
    str  x11, [x0]
    adrp x0, first_stat
    add  x0, x0, :lo12:first_stat
    str  xzr, [x0]
    mov  x22, #-1
cpu_stat_done:
skip_cpu_stat:

    // ============================================================
    // 6. RAM  →  x23 = % utilisé (-1 = indisponible)
    // ============================================================
    mov  x23, #-1
    mov  x0, #FD_IDX_MEMINFO
    adrp x1, buffer_meminfo
    add  x1, x1, :lo12:buffer_meminfo
    mov  x2, #BUFFER_MEMINFO_SIZE
    bl   read_fd_persistent
    cmp  x0, #20
    blt  mem_skip

    adrp x0, buffer_meminfo
    add  x0, x0, :lo12:buffer_meminfo
    adrp x1, needle_memtotal
    add  x1, x1, :lo12:needle_memtotal
    bl   strstr
    cbz  x0, mem_skip

    add  x1, x0, #9
.Lskip_sp_total:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq .Lskip_sp_total
    sub  x1, x1, #1
    mov  x0, x1
    bl   parse_uint
    mov  x26, x0                    // MemTotal (kB)

    adrp x0, buffer_meminfo
    add  x0, x0, :lo12:buffer_meminfo
    adrp x1, needle_memavail
    add  x1, x1, :lo12:needle_memavail
    bl   strstr
    cbz  x0, mem_skip

    add  x1, x0, #13
.Lskip_sp_avail:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq .Lskip_sp_avail
    sub  x1, x1, #1
    mov  x0, x1
    bl   parse_uint
    mov  x3, x0                     // MemAvailable (kB)

    cbz  x26, mem_skip
    sub  x5, x26, x3
    mov  x6, #100
    mul  x5, x5, x6
    udiv x23, x5, x26
mem_skip:

    // ============================================================
    // 7. Horodatage UTC  →  x15=H, x10=M, x11=S
    // ============================================================
    mov  x0, #0
    adrp x1, timespec
    add  x1, x1, :lo12:timespec
    mov  x8, #SYS_CLOCK_GETTIME
    svc  0

    adrp x3, timespec
    add  x3, x3, :lo12:timespec
    ldr  x4, [x3]

    movz x5, #0x5180
    movk x5, #0x1, lsl #16          // 86400
    mov  x6, #3600
    mov  x7, #60
    mov  x14, #10

    udiv x13, x4, x5
    msub x4,  x13, x5, x4
    udiv x15, x4, x6                // heures
    msub x4,  x15, x6, x4
    udiv x10, x4, x7                // minutes
    msub x4,  x10, x7, x4
    mov  x11, x4                    // secondes

    // ============================================================
    // 8. Construction de la ligne de sortie dans outbuf
    // ============================================================
    adrp x2, outbuf
    add  x2, x2, :lo12:outbuf

    // Effacer outbuf
    mov  x9,  #(OUTPUT_BUFFER_SIZE / 8)
    mov  x16, #0
    mov  x17, x2
.Lclear_outbuf:
    str  x16, [x17], #8
    subs x9,  x9, #1
    b.ne .Lclear_outbuf

    adrp x2, outbuf
    add  x2, x2, :lo12:outbuf

    // ---- [HH:MM:SS UTC] ----
    adrp x0, str_cyan
    add  x0, x0, :lo12:str_cyan
    bl   copy_str

    mov  w13, '['
    strb w13, [x2], #1

    udiv x13, x15, x14
    msub x15, x13, x14, x15
    add  w13, w13, '0'
    strb w13, [x2], #1
    add  w15, w15, '0'
    strb w15, [x2], #1
    mov  w13, ':'
    strb w13, [x2], #1

    udiv x13, x10, x14
    msub x10, x13, x14, x10
    add  w13, w13, '0'
    strb w13, [x2], #1
    add  w10, w10, '0'
    strb w10, [x2], #1
    mov  w13, ':'
    strb w13, [x2], #1

    udiv x13, x11, x14
    msub x11, x13, x14, x11
    add  w13, w13, '0'
    strb w13, [x2], #1
    add  w11, w11, '0'
    strb w11, [x2], #1

    adrp x0, str_utc
    add  x0, x0, :lo12:str_utc
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str
    mov  w13, ' '
    strb w13, [x2], #1

    // Restaurer température (x24=degrés, x25=dixièmes)
    mov  x6, x24
    mov  x9, x25

.if TEMP_MAX == 80
    // ---- Température CPU (Optimisation 80 sans division) ----
    mov  x1, x2

    .if MAX80_ULTRA_OPTIMIZED != 1

    .warning "---- Température CPU (calcul 80°C sans division) ----"

    // Objectif : pct = temp * 1.25
    // temp + (temp >> 2)  =>  temp + temp/4  => 1.25 * temp
    mov  x0, x24              // x0 = température entière (ex: 40)
    lsr  x13, x0, #2          // x13 = 40 >> 2 = 10
    add  x0, x0, x13          // x0 = 40 + 10 = 50 (%)
    
    // Note : Si temp = 80, x0 = 80 + 20 = 100 (%) -> Parfait.

    bl   pct_to_color
    bl   copy_str
    .else

    .warning "---- Température CPU (calcul 80°C ultra-optimisé) ----"
// ---- Température CPU (Optimisation ultime pour MAX 80) ----
// Instruction unique : add x0, x24, x24, lsr #2
// est traitée par le processeur en un seul cycle d'horloge
    mov  x1, x2               // x2 contient le pointeur actuel dans outbuf
    
    // Calcul du pourcentage : pct = temp * 1.25
    // En ARM64, cette instruction fait : x0 = x24 + (x24 >> 2)
    // Si temp = 80 : 80 + (80/4) = 100% (Rouge clignotant)
    // Si temp = 40 : 40 + (40/4) = 50%  (Jaune brillant)
    add  x0, x24, x24, lsr #2
    
    // Application de la couleur basée sur le pourcentage calculé
    bl   pct_to_color         
    bl   copy_str
    .endif

.else
    // ---- Température CPU (TOUTE VALEUR) ----
    .warning "---- Température CPU (TOUTE VALEUR) ----"

    mov  x1, x2
    
    // Calcul du pourcentage réel basé sur TEMP_MAX
    mov  x0, x24          // x24 contient les degrés entiers (ex: 45)
    mov  x13, #100
    mul  x0, x0, x13      // x0 = 4500
    mov  x13, #TEMP_MAX   // Utilise enfin la constante .equ
    udiv x0, x0, x13      // x0 = 4500 / 50 = 90 (%)
    
    bl   pct_to_color     // Maintenant x0 contient 90, donc du rouge
    bl   copy_str
.endif

.if SHOW_THERMO == 1
    adrp x0, str_thermo
    add  x0, x0, :lo12:str_thermo
    bl   copy_str
.endif

    mov  x0, x6
    bl   uint_to_str
    mov  x9, x25                    // restaurer dixièmes (uint_to_str écrase x9)
    mov  w0, '.'
    bl   write_byte
    mov  w0, w9
    add  w0, w0, '0'
    bl   write_byte
    adrp x0, str_celsius
    add  x0, x0, :lo12:str_celsius
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

    mov  x0, #COL_TEMP_WIDTH
    bl   pad_to_width
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    // ---- Fréquence CPU ----
    cmp  x18, #-1
    b.eq skip_freq

    mov  x1, x2
.if SHOW_FREQ == 1
    adrp x0, str_freq
    add  x0, x0, :lo12:str_freq
    bl   copy_str
.endif

    bl   select_cpu_color
    bl   copy_str

    mov  x0, x18
    bl   uint_to_str
    mov  w0, '.'
    bl   write_byte
    mov  w0, w21
    add  w0, w0, '0'
    bl   write_byte

    mov  x0, #COL_FREQ_WIDTH
    bl   pad_to_width
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    adrp x0, str_mhz
    add  x0, x0, :lo12:str_mhz
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

skip_freq:

    // ---- Utilisation CPU ----
    mov  x1, x2
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str
    adrp x0, str_load
    add  x0, x0, :lo12:str_load
    bl   copy_str

    cmp  x22, #-1
    b.eq .Lcpu_na

    mov  x0, x22
    bl   pct_to_color
    bl   copy_str

    mov  x0, x22
    bl   uint_to_str
    adrp x0, str_percent
    add  x0, x0, :lo12:str_percent
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str
    b    .Lcpu_pad
.Lcpu_na:
    adrp x0, str_na
    add  x0, x0, :lo12:str_na
    bl   copy_str
.Lcpu_pad:
    mov  x0, #COL_CPU_WIDTH
    bl   pad_to_width

    // ---- RAM ----
    cmp  x23, #-1
    b.eq skip_ram

    mov  x1, x2
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str
    adrp x0, str_ram
    add  x0, x0, :lo12:str_ram
    bl   copy_str

    mov  x0, x23
    bl   pct_to_color
    bl   copy_str

    mov  x0, x23
    bl   uint_to_str
    adrp x0, str_percent
    add  x0, x0, :lo12:str_percent
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

    mov  x0, #COL_RAM_WIDTH
    bl   pad_to_width

skip_ram:

    // ---- Under-voltage ----
    cmp  x20, #1
    b.eq .Lunder_voltage
    cmp  x20, #0
    b.eq .Lvoltage_normal
    b    skip_voltage
.Lunder_voltage:
    mov  x1, x2
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    adrp x0, str_undervolt
    add  x0, x0, :lo12:str_undervolt
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str
    b    .Luv_pad
.Lvoltage_normal:
    mov  x1, x2
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str
    adrp x0, str_ok
    add  x0, x0, :lo12:str_ok
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str
.Luv_pad:
    mov  x0, #COL_UV_WIDTH
    bl   pad_to_width
skip_voltage:

    // ---- Load averages ----
    cmp  x27, #1
    b.ne skip_loadavg

    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    mov  x26, x2
    adrp x0, str_color_1m
    add  x0, x0, :lo12:str_color_1m
    bl   copy_str
    adrp x0, str_1m
    add  x0, x0, :lo12:str_1m
    bl   copy_str
    adrp x0, buffer_load
    add  x0, x0, :lo12:buffer_load
    mov  x1, #0
    bl   skip_and_copy_nth_word
    mov  x1, x26
    mov  x0, #COL_LA_WIDTH
    bl   pad_to_width

    mov  x26, x2
    adrp x0, str_color_5m
    add  x0, x0, :lo12:str_color_5m
    bl   copy_str
    adrp x0, str_5m
    add  x0, x0, :lo12:str_5m
    bl   copy_str
    adrp x0, buffer_load
    add  x0, x0, :lo12:buffer_load
    mov  x1, #1
    bl   skip_and_copy_nth_word
    mov  x1, x26
    mov  x0, #COL_LA_WIDTH
    bl   pad_to_width

    adrp x0, str_color_15m
    add  x0, x0, :lo12:str_color_15m
    bl   copy_str
    adrp x0, str_15m
    add  x0, x0, :lo12:str_15m
    bl   copy_str
    adrp x0, buffer_load
    add  x0, x0, :lo12:buffer_load
    mov  x1, #2
    bl   skip_and_copy_nth_word

skip_loadavg:

    // ---- Fin de ligne + écriture ----
    mov  w3, '\n'
    cmp  x2, x28
    b.ge .Lwrite_out
    strb w3, [x2], #1

.Lwrite_out:
    adrp x3, outbuf
    add  x3, x3, :lo12:outbuf
    sub  x12, x2, x3
    mov  x0, #STDOUT
    mov  x1, x3
    mov  x2, x12
    mov  x8, #SYS_WRITE
    svc  0

    // ---- Pause 1 seconde ----
    adrp x0, sleep_ts
    add  x0, x0, :lo12:sleep_ts
    mov  x1, #0
    mov  x8, #SYS_NANOSLEEP
    svc  0

    b    loop

// ================================================================
// _exit : sortie propre (SIGTERM)
// ================================================================
_exit:
    mov  x0, #0
    mov  x8, #SYS_EXIT
    svc  0

