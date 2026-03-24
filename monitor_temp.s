/*
 * ==================================================================
 * Fichier     : monitor_temp.s
 * Version     : 2.5b
 * Date        : 2026-03-23
 * Auteur      : /B4SH 😎
 * ------------------------------------------------------------------
 * LANGAGE     : ASSEMBLEUR AArch64 (ARMv8-A)
 * DESCRIPTION : Monitoring système temps réel pour Raspberry Pi 4B
 *               Version refactorisée v2.5 :
 *               - fd persistants (lseek au lieu de open/close)
 *               - vérification de bornes sur outbuf
 *               - skip_and_copy_nth_word factorisé (copy_1m/5m/15m)
 *               - pad_to_width avec pointeur de début explicite (x1)
 *               - seuils de couleur en constantes nommées
 *               - strstr maison pour /proc/meminfo
 *               - affichage "--" au 1er tour CPU
 *               - x9 remplace x8 comme scratch dans uint_to_str
 * Compilation :
 * $ as -o monitor_temp.o monitor_temp.s
 * $ gcc -nostdlib -static -o monitor-temp-ASM monitor_temp.o
 * $ strip monitor-temp-ASM
 * ==================================================================
 */

.global _start

// ---------------------------------------------------------------
// Options de compilation
// ---------------------------------------------------------------
.equ SHOW_FREQ,             1       // 1 pour activer, 0 pour désactiver
.equ SHOW_THERMO,           1

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
.equ COL_TEMP_WIDTH,        6       // "103.7°C" + marge
.equ COL_FREQ_WIDTH,        8       // "F:2400.0MHz"
.equ COL_CPU_WIDTH,         7       // "L:100%" // ancienne valeur erronée : 6
.equ COL_RAM_WIDTH,         7       // "M:100%" // ancienne valeur erronée : 6
.equ COL_UV_WIDTH,          4       // "⚡️❌"
.equ COL_LA_WIDTH,          8       // "1m:12.35"

// ---------------------------------------------------------------
// Seuils de couleur (température en °C)
// ---------------------------------------------------------------
.equ TEMP_WARN,             50
.equ TEMP_HOT,              65
.equ TEMP_CRITICAL,         80

// Seuils CPU (%)
.equ CPU_WARN,              25
.equ CPU_HOT,               50
.equ CPU_CRITICAL,          75

// Seuils RAM (%)
.equ RAM_WARN,              50
.equ RAM_CRITICAL,          80

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

// ---------------------------------------------------------------
.section .data
// ---------------------------------------------------------------

// Codes couleur ANSI
str_cyan:           .asciz "\033[36m"
str_blue:           .asciz "\033[34m"
str_green:          .asciz "\033[32m"
str_yellow:         .asciz "\033[33m"
str_orange:         .asciz "\033[38;5;208m"
str_orange_dark:    .asciz "\033[38;5;202m"
str_red:            .asciz "\033[31m"
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
str_na:             .asciz "--"     // affiché si métrique indisponible

// Chaînes ANSI 256 (vert → rouge) par palier de fréquence CPU
str_600MHz:         .asciz "\033[38;5;34m"    // vert foncé
str_700MHz:         .asciz "\033[38;5;40m"    // vert
str_800MHz:         .asciz "\033[38;5;46m"    // vert clair
str_900MHz:         .asciz "\033[38;5;82m"    // vert-jaune
str_1000MHz:        .asciz "\033[38;5;118m"   // jaune-vert
str_1100MHz:        .asciz "\033[38;5;154m"   // jaune vif
str_1200MHz:        .asciz "\033[38;5;190m"   // jaune clair
str_1300MHz:        .asciz "\033[38;5;220m"   // jaune-orangé
str_1400MHz:        .asciz "\033[38;5;214m"   // orange
str_1500MHz:        .asciz "\033[38;5;208m"   // orange soutenu
str_1600MHz:        .asciz "\033[38;5;202m"   // rouge-orangé
str_1700MHz:        .asciz "\033[38;5;160m"   // rouge sombre (ma préférence pour cet ordre)
str_1800MHz:        .asciz "\033[38;5;196m"   // rouge vif (ma préférence puor cet ordre)

// Table de pointeurs de couleurs indexée par palier 100 MHz
// index = (freq_MHz - 600) / 100  ∈ [0..12]
.align 3
cpu_color_table:
        .quad   str_600MHz      // index 0  → 600 MHz
        .quad   str_700MHz      // index 1  → 700 MHz
        .quad   str_800MHz      // index 2  → 800 MHz
        .quad   str_900MHz      // index 3  → 900 MHz
        .quad   str_1000MHz     // index 4  → 1000 MHz
        .quad   str_1100MHz     // index 5  → 1100 MHz
        .quad   str_1200MHz     // index 6  → 1200 MHz
        .quad   str_1300MHz     // index 7  → 1300 MHz
        .quad   str_1400MHz     // index 8  → 1400 MHz
        .quad   str_1500MHz     // index 9  → 1500 MHz
        .quad   str_1600MHz     // index 10 → 1600 MHz
        .quad   str_1700MHz     // index 11 → 1700 MHz
        .quad   str_1800MHz     // index 12 → 1800 MHz

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

// Buffers de lecture
buffer:         .space BUFFER_SIZE
buffer_thr:     .space BUFFER_THR_SIZE
buffer_freq:    .space BUFFER_FREQ_SIZE
buffer_load:    .space BUFFER_LOAD_SIZE
buffer_stat:    .space BUFFER_STAT_SIZE
buffer_meminfo: .space BUFFER_MEMINFO_SIZE

// Buffers de sortie
outbuf:     .space OUTPUT_BUFFER_SIZE

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
// copy_str : copie une chaîne ASCIIZ de x0 vers (x2), met à jour x2
// Vérifie que x2 ne dépasse pas outbuf_end (x28)
// Utilise w3 comme scratch (préserve x1 = début de champ)
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
// Entrée : x0 = chemin, x1 = index dans fd_table
// Sortie : x0 = fd (ou -1)
// ================================================================
open_fd:
    stp  x4, lr, [sp, #-16]!
    mov  x4, x1                     // sauver index
    mov  x1, x0                     // chemin
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
// read_fd_persistent : rewind + lecture d'un fd persistant
// Entrée : x0 = index fd_table, x1 = buffer, x2 = taille max
// Sortie : x0 = octets lus, ou -1
// ================================================================
read_fd_persistent:
    stp  x4, x5,  [sp, #-32]!
    stp  x6, lr,  [sp, #16]

    mov  x4, x1                     // sauver buffer
    mov  x5, x2                     // sauver taille
    mov  x6, x0                     // sauver index

    // charger le fd depuis fd_table
    adrp x1, fd_table
    add  x1, x1, :lo12:fd_table
    ldr  x3, [x1, x6, lsl #3]
    cmp  x3, #0
    blt  .Lrfp_err                  // fd invalide

    // lseek(fd, 0, SEEK_SET)
    mov  x0, x3
    mov  x1, #0
    mov  x2, #SEEK_SET
    mov  x8, #SYS_LSEEK
    svc  0

    // read(fd, buf, size)
    mov  x0, x3
    mov  x1, x4
    mov  x2, x5
    mov  x8, #SYS_READ
    svc  0
    cmp  x0, #0
    blt  .Lrfp_err

    // null-terminator si place
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
// Entrée : x0 = pointeur
// Sortie : x0 = valeur, x1 = pointeur après
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
    add  x5, x5, x5, lsl #2        // x5 * 5
    lsl  x5, x5, #1                // x5 * 10
    add  x5, x5, x7
    b    1b
2:
    sub  x6, x6, #1
    mov  x0, x5
    mov  x1, x6
    ret

// ================================================================
// parse_hex : chaîne hexadécimale → entier 64 bits
// Entrée : x0 = pointeur
// Sortie : x0 = valeur, x1 = pointeur après
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
// Entrée : x0 = valeur, x2 = pointeur buffer (mis à jour)
// Note : x9 utilisé comme scratch (jamais x8 = numéro syscall)
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
    msub x9, x7, x5, x4             // reste (x9, pas x8)
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
// strstr (simple) : recherche needle dans haystack (version fiable)
// Entrée : x0 = haystack, x1 = needle
// Sortie : x0 = pointeur sur occurrence, ou 0
// ================================================================
strstr:
    mov  x2, x0                     // curseur haystack
.Lss_outer:
    ldrb w3, [x2]                   // premier caractère du haystack
    cbz  w3, .Lss_notfound
    mov  x4, x2                     // début de la comparaison
    mov  x5, x1                     // début du needle
.Lss_inner:
    ldrb w6, [x5], #1
    cbz  w6, .Lss_found             // fin du needle → trouvé
    ldrb w7, [x4], #1
    cbz  w7, .Lss_advance           // fin du haystack → pas trouvé ici
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
// pad_to_width : aligne une colonne en ajoutant des espaces
// Entrée : x0 = largeur voulue, x1 = début du champ, x2 = fin
// Sortie : x2 mis à jour
// ================================================================
pad_to_width:
    mov  x3, x1                     // curseur (début du champ)
    mov  x4, #0                     // largeur visuelle

.Lptw_scan:
    cmp  x3, x2
    beq  .Lptw_pad

    ldrb w5, [x3]

    // Séquence ANSI : ESC[...m → largeur 0
    cmp  w5, #0x1B
    bne  .Lptw_utf8
    add  x3, x3, #1
    ldrb w6, [x3]
    cmp  w6, #'['
    bne  .Lptw_scan                 // ESC seul, ignorer
.Lptw_ansi_skip:
    add  x3, x3, #1
    ldrb w6, [x3]
    cmp  w6, #'m'
    bne  .Lptw_ansi_skip
    add  x3, x3, #1
    b    .Lptw_scan

.Lptw_utf8:
    // Emoji 4 octets → largeur 2
    cmp  w5, #0xF0
    bge  .Lptw_4b
    // UTF-8 3 octets → largeur 1
    cmp  w5, #0xE0
    bge  .Lptw_3b
    // UTF-8 2 octets → largeur 1
    cmp  w5, #0xC0
    bge  .Lptw_2b
    // ASCII → largeur 1
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
// select_cpu_color : fréquence (x18, MHz) → pointeur ANSI (x0)
// Utilise cpu_color_table (pointeurs ANSI par pas de 100 MHz)
// Préserve x1, x2
// ================================================================
select_cpu_color:
    stp     x1, lr, [sp, #-16]!

    // index = (freq - 600) / 100
    sub     x9, x18, #600
    mov     x3, #100
    sdiv    x9, x9, x3

    // clamp 0..12
    cmp     x9, #0
    csel    x9, xzr, x9, lt
    cmp     x9, #12
    csel    x9, x9, x9, gt

    // load pointer
    adrp    x3, cpu_color_table
    add     x3, x3, :lo12:cpu_color_table
    ldr     x0, [x3, x9, lsl #3]

    ldp     x1, lr, [sp], #16
    ret

// ================================================================
// skip_and_copy_nth_word : extrait le (n+1)ème mot d'une chaîne
// Entrée : x0 = buffer, x1 = n (nombre de mots à sauter), x2 = outbuf
// Sortie : x2 mis à jour
// ================================================================
skip_and_copy_nth_word:
    stp  x6, lr, [sp, #-16]!
    mov  x6, x1                     // compteur de mots à sauter
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
    bl   open_all_fds

    // x28 = outbuf + OUTPUT_BUFFER_SIZE (sentinelle de sécurité)
    adrp x28, outbuf
    add  x28, x28, :lo12:outbuf
    add  x28, x28, #OUTPUT_BUFFER_SIZE

loop:

    // ============================================================
    // 1. Température CPU
    // ============================================================
    mov  x0, #FD_IDX_TEMP
    adrp x1, buffer
    add  x1, x1, :lo12:buffer
    mov  x2, #BUFFER_SIZE
    bl   read_fd_persistent
    cmp  x0, #3
    b.lt loop                       // fichier invalide, réessayer

    adrp x0, buffer
    add  x0, x0, :lo12:buffer
    bl   parse_uint
    mov  x3, x0                     // milli°C

    mov  x5, #1000
    udiv x6, x3, x5                 // degrés entiers
    msub x7, x6, x5, x3
    mov  x5, #100
    udiv x9, x7, x5                 // dixièmes

    mov  x24, x6                    // degrés (préservé)
    mov  x25, x9                    // dixièmes (préservé)

    // ============================================================
    // 2. Under-voltage
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
    // 3. Fréquence CPU
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
    mov  x16, x0                    // kHz

    mov  x17, #1000
    udiv x18, x16, x17              // MHz entiers
    msub x19, x18, x17, x16
    mov  x17, #100
    udiv x21, x19, x17              // dixièmes MHz
freq_done:

    // ============================================================
    // 4. Load average
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
    // 5. Utilisation CPU (/proc/stat)
    // ============================================================
    mov  x0, #FD_IDX_STAT
    adrp x1, buffer_stat
    add  x1, x1, :lo12:buffer_stat
    mov  x2, #BUFFER_STAT_SIZE
    bl   read_fd_persistent
    cmp  x0, #0
    blt  skip_cpu_stat

    // strstr(buffer_stat, "cpu ")
    adrp x0, buffer_stat
    add  x0, x0, :lo12:buffer_stat
    adrp x1, needle_cpu
    add  x1, x1, :lo12:needle_cpu
    bl   strstr
    cbz  x0, skip_cpu_stat

    // x0 pointe sur "cpu ", avancer de 4
    add  x1, x0, #4

    // sauter espaces supplémentaires
.Lskip_spaces_stat:
    ldrb w2, [x1], #1
    cmp  w2, #' '
    b.eq .Lskip_spaces_stat
    sub  x1, x1, #1

    // lire 8 nombres
    sub  sp, sp, #64
    mov  x4, sp
    mov  x2, #0
parse_stat_numbers:
    mov  x0, x1
    bl   parse_uint
    // parse_uint retourne valeur dans x0, pointeur après dans x1
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
    ldr  x6,  [sp, #24]
    ldr  x7,  [sp, #32]
    ldr  x9,  [sp, #40]
    ldr  x10, [sp, #48]
    ldr  x11, [sp, #56]
    add  sp, sp, #64

    // total = somme des 8 champs
    add  x11, x3,  x4
    add  x11, x11, x5
    add  x11, x11, x6
    add  x11, x11, x7
    add  x11, x11, x9
    add  x11, x11, x10
    // x6 = idle (champ 4, index 3)

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

    sub  x14, x6,  x12              // delta idle
    sub  x15, x11, x13              // delta total
    cbz  x15, cpu_stat_done
    sub  x16, x15, x14              // temps actif
    mov  x17, #100
    mul  x16, x16, x17
    udiv x22, x16, x15              // % CPU dans x22

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
    mov  x22, #-1                   // -1 = pas encore de mesure (affichera "--")
cpu_stat_done:
skip_cpu_stat:


    // ============================================================
    // 6. Mémoire RAM (/proc/meminfo)
    // ============================================================
    mov  x23, #-1
    mov  x0, #FD_IDX_MEMINFO
    adrp x1, buffer_meminfo
    add  x1, x1, :lo12:buffer_meminfo
    mov  x2, #BUFFER_MEMINFO_SIZE
    bl   read_fd_persistent
    cmp  x0, #20
    blt  mem_skip

    // strstr(buffer_meminfo, "MemTotal:")
    adrp x0, buffer_meminfo
    add  x0, x0, :lo12:buffer_meminfo
    adrp x1, needle_memtotal
    add  x1, x1, :lo12:needle_memtotal
    bl   strstr
    cbz  x0, mem_skip

    // sauter "MemTotal:" (9 octets) + espaces
    add  x1, x0, #9
.Lskip_sp_total:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq .Lskip_sp_total
    sub  x1, x1, #1
    mov  x0, x1
    bl   parse_uint
    mov  x26, x0

    // strstr depuis le début du buffer pour MemAvailable:
    adrp x0, buffer_meminfo
    add  x0, x0, :lo12:buffer_meminfo
    adrp x1, needle_memavail
    add  x1, x1, :lo12:needle_memavail
    bl   strstr
    cbz  x0, mem_skip

    // sauter "MemAvailable:" (13 octets) + espaces
    add  x1, x0, #13
.Lskip_sp_avail:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq .Lskip_sp_avail
    sub  x1, x1, #1
    mov  x0, x1
    bl   parse_uint
    mov  x3, x0                     // MemAvailable (kB)

    // % utilisé = (MemTotal - MemAvailable) * 100 / MemTotal
    cbz  x26, mem_skip
    sub  x5, x26, x3
    mov  x6, #100
    mul  x5, x5, x6
    udiv x23, x5, x26
mem_skip:

    // ============================================================
    // 7. Horodatage UTC → calculer H/M/S, écrire dans outbuf
    // ============================================================
    mov  x0, #0                     // CLOCK_REALTIME
    adrp x1, timespec
    add  x1, x1, :lo12:timespec
    mov  x8, #SYS_CLOCK_GETTIME
    svc  0

    adrp x3, timespec
    add  x3, x3, :lo12:timespec
    ldr  x4, [x3]                   // secondes Unix

    movz x5, #0x5180
    movk x5, #0x1, lsl #16          // 86400

    mov  x6, #3600
    mov  x7, #60
    mov  x14, #10

    udiv x13, x4, x5                // jours (ignoré)
    msub x4,  x13, x5, x4          // secondes dans la journée
    udiv x15, x4, x6                // x15 = heures
    msub x4,  x15, x6, x4
    udiv x10, x4, x7                // x10 = minutes
    msub x4,  x10, x7, x4
    mov  x11, x4                    // x11 = secondes

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
    subs x9,  x9,  #1
    b.ne .Lclear_outbuf

    adrp x2, outbuf
    add  x2, x2, :lo12:outbuf

    // ---- Timestamp [HH:MM:SS UTC] ----
    adrp x0, str_cyan
    add  x0, x0, :lo12:str_cyan
    bl   copy_str

    mov  w13, '['
    strb w13, [x2], #1

    // HH
    udiv x13, x15, x14
    msub x15, x13, x14, x15
    add  w13, w13, '0'
    strb w13, [x2], #1
    add  w15, w15, '0'
    strb w15, [x2], #1
    mov  w13, ':'
    strb w13, [x2], #1

    // MM
    udiv x13, x10, x14
    msub x10, x13, x14, x10
    add  w13, w13, '0'
    strb w13, [x2], #1
    add  w10, w10, '0'
    strb w10, [x2], #1
    mov  w13, ':'
    strb w13, [x2], #1

    // SS
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

    // Restaurer température
    mov  x6, x24
    mov  x9, x25

    // ---- Température CPU ----
    mov  x1, x2                     // début du champ (pour pad_to_width)

    mov  x0, x6
    cmp  x0, #TEMP_CRITICAL
    b.ge .Ltemp_red
    cmp  x0, #TEMP_HOT
    b.ge .Ltemp_orange
    cmp  x0, #TEMP_WARN
    b.ge .Ltemp_yellow
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str
    b    .Ltemp_color_done
.Ltemp_red:
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    b    .Ltemp_color_done
.Ltemp_orange:
    adrp x0, str_orange
    add  x0, x0, :lo12:str_orange
    bl   copy_str
    b    .Ltemp_color_done
.Ltemp_yellow:
    adrp x0, str_yellow
    add  x0, x0, :lo12:str_yellow
    bl   copy_str
.Ltemp_color_done:

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
    cmp  x0, #CPU_CRITICAL
    b.ge .Lcpu_red
    cmp  x0, #CPU_HOT
    b.ge .Lcpu_orange
    cmp  x0, #CPU_WARN
    b.ge .Lcpu_yellow
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str
    b    .Lcpu_color_done
.Lcpu_red:
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    b    .Lcpu_color_done
.Lcpu_orange:
    adrp x0, str_orange
    add  x0, x0, :lo12:str_orange
    bl   copy_str
    b    .Lcpu_color_done
.Lcpu_yellow:
    adrp x0, str_yellow
    add  x0, x0, :lo12:str_yellow
    bl   copy_str
.Lcpu_color_done:
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
    cmp  x0, #RAM_CRITICAL
    b.ge .Lram_red
    cmp  x0, #RAM_WARN
    b.ge .Lram_yellow
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str
    b    .Lram_color_done
.Lram_red:
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    b    .Lram_color_done
.Lram_yellow:
    adrp x0, str_yellow
    add  x0, x0, :lo12:str_yellow
    bl   copy_str
.Lram_color_done:
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

    // 1m (mot 0)
    mov  x26, x2                    // sauver début du champ
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
    mov  x1, x26                    // restaurer début du champ
    mov  x0, #COL_LA_WIDTH
    bl   pad_to_width

    // 5m (mot 1)
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

    // 15m (mot 2)
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

    // ---- Fin de ligne ----
    mov  w3, '\n'
    cmp  x2, x28
    b.ge .Lwrite_out
    strb w3, [x2], #1

    // ---- Écriture sur stdout ----
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
// _exit : sortie propre (atteignable via SIGTERM si souhaité)
// ================================================================
_exit:
    mov  x0, #0
    mov  x8, #SYS_EXIT
    svc  0

// ================================================================
// Note : x9 est utilisé comme registre des heures dans le bloc
// horodatage. GNU as (AArch64) ne supporte pas les alias de
// registres — x9 est réutilisé directement.
// ================================================================
