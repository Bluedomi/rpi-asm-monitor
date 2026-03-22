/*
 * ==================================================================
 * Fichier     : monitor_temp.s
 * Version     : 2.4
 * Date        : 2026-03-22
 * Auteur      : /B4SH 😎
 * ------------------------------------------------------------------
 * LANGAGE     : ASSEMBLEUR AArch64 (ARMv8-A)
 * DESCRIPTION : Monitoring système temps réel pour Raspberry Pi 4B
 *               Version refactorisée avec routines factorisées.
 * Compilation :
 * $ as -o monitor_temp.o monitor_temp.s
 * $ gcc -nostdlib -static -o monitor-temp-ASM monitor_temp.o
 * $ strip monitor-temp-ASM
 * ==================================================================
 */

.global _start

// Options de compilation
.equ SHOW_FREQ,     1  // 1 pour activer, 0 pour désactiver
.equ SHOW_THERMO,   1

.equ BUFFER_MEMINFO_SIZE,   128 // previously 1024
.equ OUTPUT_BUFFER_SIZE,    256 // previously 512
//.equ OUTPUT_BUFFER_SIZE,    512 // previously 512            
.equ BUFFER_STAT_SIZE,      128 // previously 256
.equ TIME_BUFFER_SIZE,      64  // previously 128

// Largeurs de colonnes (en caractères visibles)
.equ COL_TEMP_WIDTH,        6     // "103.7°C" + marge
.equ COL_FREQ_WIDTH,        8     // "F:2400.0MHz"
.equ COL_CPU_WIDTH,         6     // "L:100%"
.equ COL_RAM_WIDTH,         6     // "M:100%"
.equ COL_UV_WIDTH,          4     // "⚡️❌"
.equ COL_LA_WIDTH,          8     // "1m:12.35"

// .global _start

// Syscalls (constantes)
.equ SYS_OPENAT,            56
.equ SYS_READ,              63
.equ SYS_WRITE,             64
.equ SYS_CLOSE,             57
.equ SYS_NANOSLEEP,         101
.equ SYS_EXIT,              93
.equ SYS_CLOCK_GETTIME,     113

.section .data

// Chaînes constantes
str_cyan:       .asciz "\033[36m"
str_blue:       .asciz "\033[34m"
str_green:      .asciz "\033[32m"
str_yellow:     .asciz "\033[33m"
str_orange:     .asciz "\033[38;5;208m"
str_orange_dark:.asciz "\033[38;5;202m"
str_red:        .asciz "\033[31m"
str_reset:      .asciz "\033[0m"

.equ str_color_1m,   str_blue
.equ str_color_5m,   str_blue
.equ str_color_15m,  str_blue

str_freq:       .asciz "F:"
str_load:       .asciz "L:"
str_ram:        .asciz "M:"
str_mhz:        .asciz "MHz"
str_thermo:     .asciz " 🌡 "
str_celsius:    .asciz "°C"
str_ok:         .asciz "⚡️✅"
str_undervolt:  .asciz "⚡️❌"
str_space:      .asciz " "
str_percent:    .asciz "%"
str_1m:         .asciz "1m:"
str_5m:         .asciz "5m:"
str_15m:        .asciz "15m:"
str_utc:        .asciz " UTC]"

// Chaînes ANSI 256 pour chaque fréquence CPU
str_600MHz:   .asciz "\033[38;5;34m"
str_700MHz:   .asciz "\033[38;5;40m"
str_800MHz:   .asciz "\033[38;5;46m"
str_900MHz:   .asciz "\033[38;5;82m"
str_1000MHz:  .asciz "\033[38;5;118m"
str_1100MHz:  .asciz "\033[38;5;154m"
str_1200MHz:  .asciz "\033[38;5;190m"
str_1300MHz:  .asciz "\033[38;5;184m"
str_1400MHz:  .asciz "\033[38;5;178m"
str_1500MHz:  .asciz "\033[38;5;172m"
str_1600MHz:  .asciz "\033[38;5;208m"
str_1700MHz:  .asciz "\033[38;5;202m"
str_1800MHz:  .asciz "\033[38;5;196m"
//str_reset:    .asciz "\033[0m"

// Fichiers
filepath_temp:
    .asciz "/sys/class/thermal/thermal_zone0/temp"
filepath_throttled:
    .asciz "/sys/devices/platform/soc/soc:firmware/get_throttled"
filepath_freq:
    .asciz "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
filepath_loadavg:
    .asciz "/proc/loadavg"
filepath_stat:
    .asciz "/proc/stat"
filepath_meminfo:
    .asciz "/proc/meminfo"

// Buffers
buffer:
    .space 16
buffer_thr:
    .space 16
buffer_freq:
    .space 16
buffer_load:
    .space 64

buffer_stat:
    .space BUFFER_STAT_SIZE

buffer_meminfo:
    .space BUFFER_MEMINFO_SIZE 

outbuf:
    .space OUTPUT_BUFFER_SIZE

timebuf:
    .space TIME_BUFFER_SIZE

sleep_ts:
    .quad 1
    .quad 0

.balign 16
timespec:
    .quad 0
    .quad 0

// Variables pour calcul CPU
prev_idle:
    .quad 0
prev_total:
    .quad 0
first_stat:
    .quad 1

// Table fréquence (MHz) → pointeur vers chaîne ANSI
.balign 8
cpu_color_table:
    .quad 600,  str_600MHz
    .quad 700,  str_700MHz
    .quad 800,  str_800MHz
    .quad 900,  str_900MHz
    .quad 1000, str_1000MHz
    .quad 1100, str_1100MHz
    .quad 1200, str_1200MHz
    .quad 1300, str_1300MHz
    .quad 1400, str_1400MHz
    .quad 1500, str_1500MHz
    .quad 1600, str_1600MHz
    .quad 1700, str_1700MHz
    .quad 1800, str_1800MHz
cpu_color_table_end:


.section .text

// -----------------------------------------------------------------
// copy_str : copie une chaîne ASCIIZ de x0 vers (x2), met à jour x2
// -----------------------------------------------------------------
copy_str:
    ldrb w1, [x0], #1
    cbz  w1, 1f
    strb w1, [x2], #1
    b    copy_str
1:  ret

// -------------------------------------------------------------------
// read_file : ouvre, lit et ferme un fichier, ajoute '\0' si possible
// Entrée : x0 = chemin, x1 = buffer, x2 = taille max
// Sortie : x0 = nombre d'octets lus, ou -1 si erreur
// -------------------------------------------------------------------
read_file:
    stp x4, x5, [sp, #-16]!   // sauvegarde x4, x5
    mov x4, x1                 // sauve buffer
    mov x5, x2                 // sauve taille
    // openat
    mov x1, x0                 // chemin
    mov x0, #-100              // AT_FDCWD
    mov x2, #0
    mov x3, #0
    mov x8, #SYS_OPENAT
    svc 0
    cmp x0, #0
    blt .Lread_err             // erreur open
    mov x3, x0                 // fd
    // read
    mov x0, x3
    mov x1, x4                 // buffer
    mov x2, x5                 // taille max
    mov x8, #SYS_READ
    svc 0
    cmp x0, #0
    blt .Lread_err_close       // erreur lecture
    mov x6, x0                 // taille lue
    // close
    mov x0, x3
    mov x8, #SYS_CLOSE
    svc 0
    // ajouter null-terminateur si place
    cmp x6, x5
    b.ge .Lread_no_null
    add x1, x4, x6
    strb wzr, [x1]            // '\0'
.Lread_no_null:
    mov x0, x6                 // retour taille lue
    ldp x4, x5, [sp], #16
    ret
.Lread_err_close:
    mov x0, x3
    mov x8, #SYS_CLOSE
    svc 0
.Lread_err:
    mov x0, #-1
    ldp x4, x5, [sp], #16
    ret

// ------------------------------------------------------------
// parse_uint : convertit une chaîne décimale en entier 64 bits
// Entrée : x0 = pointeur début du nombre
// Sortie : x0 = valeur, x1 = pointeur après le nombre
// ------------------------------------------------------------
parse_uint:
    mov x5, #0                 // accumulateur
    mov x6, x0                 // pointeur courant
1:
    ldrb w7, [x6], #1
    cmp w7, #'0'
    blt 2f
    cmp w7, #'9'
    bgt 2f
    sub w7, w7, #'0'
    uxtw x7, w7
    add x5, x5, x5, lsl #2     // x5 = x5 * 5
    lsl x5, x5, #1             // x5 = x5 * 10
    add x5, x5, x7
    b 1b
2:
    sub x6, x6, #1
    mov x0, x5
    mov x1, x6
    ret

// ------------------------------------------------------------------------------
// parse_hex : convertit une chaîne hexadécimale (sans préfixe) en entier 64 bits
// Entrée : x0 = pointeur début du nombre
// Sortie : x0 = valeur, x1 = pointeur après le nombre
// ------------------------------------------------------------------------------
parse_hex:
    mov x5, #0
    mov x6, x0
1:
    ldrb w7, [x6], #1
    cmp w7, #'0'
    blt 2f
    cmp w7, #'9'
    ble .Ldigit
    cmp w7, #'A'
    blt 2f
    cmp w7, #'F'
    ble .Lupper
    cmp w7, #'a'
    blt 2f
    cmp w7, #'f'
    ble .Llower
    b 2f
.Ldigit:
    sub w7, w7, #'0'
    b .Lstore
.Lupper:
    sub w7, w7, #'A'
    add w7, w7, #10
    b .Lstore
.Llower:
    sub w7, w7, #'a'
    add w7, w7, #10
.Lstore:
    uxtw x7, w7
    lsl x5, x5, #4
    add x5, x5, x7
    b 1b
2:
    sub x6, x6, #1
    mov x0, x5
    mov x1, x6
    ret

// ------------------------------------------------------------
// uint_to_str : convertit un entier 64 bits en chaîne décimale
// Entrée : x0 = valeur, x2 = pointeur buffer (sera mis à jour)
// Sortie : x2 pointe après le dernier caractère écrit
// ------------------------------------------------------------
uint_to_str:
    sub sp, sp, #32            // réserve 32 octets sur la pile
    mov x3, sp                 // début de la zone
    mov x4, x0                 // valeur
    mov x5, #10
    mov x6, #0                 // compteur de chiffres

    // Cas particulier : valeur == 0
    cbnz x4, 1f
    mov w8, '0'
    strb w8, [x2], #1
    add sp, sp, #32
    ret

1:
    udiv x7, x4, x5
    msub x8, x7, x5, x4        // reste
    add w8, w8, '0'
    strb w8, [x3, x6]          // stocke dans l'ordre inverse
    add x6, x6, #1
    mov x4, x7
    cbnz x4, 1b

    // maintenant x6 = nombre de chiffres
    add x3, x3, x6
    sub x3, x3, #1             // pointe sur le dernier caractère stocké
2:
    ldrb w8, [x3], #-1
    strb w8, [x2], #1
    subs x6, x6, #1
    b.ne 2b

    add sp, sp, #32
    ret

// ---------------------------------------------------------------------------------
// pad_to_width : aligne la colonne en ajoutant des espaces (ignore ANSI et emojis).
// Entrée : x0 = largeur visuelle voulue, x2 = pointeur courant dans outbuf
// Sortie : x2 mis à jour après padding
// ---------------------------------------------------------------------------------
pad_to_width:
    mov x3, x2          // pointeur de scan
    mov x4, #0          // largeur visuelle

// Reculer jusqu'au début du champ (sur espace ou début)
1:
    sub x3, x3, #1
    ldrb w5, [x3]
    cmp w5, ' '
    beq 2f
    cmp w5, #0x0A
    beq 2f
    cmp x3, #0
    bne 1b

2:
    add x3, x3, #1      // x3 = début du champ

// Parcourir le champ pour calculer la largeur visuelle
3:
    cmp x3, x2
    beq 6f              // fin du champ

    ldrb w5, [x3]

    // Séquence ANSI ? ESC = 0x1B
    cmp w5, #0x1B
    bne 4f

    // Sauter ESC [
    add x3, x3, #1
    ldrb w6, [x3]
    cmp w6, #'['
    bne 3b

5:  // Sauter jusqu'à 'm'
    add x3, x3, #1
    ldrb w6, [x3]
    cmp w6, #'m'
    bne 5b
    add x3, x3, #1
    b 3b

4:
    // Emoji UTF‑8 (4 octets) → largeur 2
    cmp w5, #0xF0
    bge 7f

    // UTF‑8 3 octets → largeur 1
    cmp w5, #0xE0
    bge 8f

    // UTF‑8 2 octets → largeur 1
    cmp w5, #0xC0
    bge 9f

    // ASCII → largeur 1
    add x4, x4, #1
    add x3, x3, #1
    b 3b

7:  // Emoji (4 octets)
    add x4, x4, #2
    add x3, x3, #4
    b 3b

8:  // UTF‑8 3 octets
    add x4, x4, #1
    add x3, x3, #3
    b 3b

9:  // UTF‑8 2 octets
    add x4, x4, #1
    add x3, x3, #2
    b 3b

// Ajouter les espaces nécessaires
6:
    cmp x4, x0
    bge 10f

    mov w5, ' '
11:
    strb w5, [x2], #1
    add x4, x4, #1
    cmp x4, x0
    blt 11b

10:
    ret

// -------------------
// Programme principal
// -------------------
_start:
    // boucle infinie
loop:
    // ------------------
    // 1. Température CPU
    // ------------------
    adrp x0, filepath_temp
    add  x0, x0, :lo12:filepath_temp
    adrp x1, buffer
    add  x1, x1, :lo12:buffer
    mov  x2, #16
    bl   read_file
    cmp  x0, #3
    b.lt loop                     // si fichier invalide, on recommence

    adrp x0, buffer
    add  x0, x0, :lo12:buffer
    bl   parse_uint
    mov  x3, x0                   // x3 = température en milli°C

    // calcul degrés et dixièmes
    mov  x5, #1000
    udiv x6, x3, x5               // x6 = degrés entiers
    msub x7, x6, x5, x3
    mov  x5, #100
    udiv x8, x7, x5               // x8 = dixièmes

    // Sauvegarde des valeurs de température (registres préservés)
    mov x24, x6
    mov x25, x8

    // ----------------------------
    // 2. Under‑voltage (throttled)
    // ----------------------------
    mov  x20, #-1                  // par défaut : inconnu
    adrp x0, filepath_throttled
    add  x0, x0, :lo12:filepath_throttled
    adrp x1, buffer_thr
    add  x1, x1, :lo12:buffer_thr
    mov  x2, #16
    bl   read_file
    cmp  x0, #0
    blt  throttle_done

    adrp x0, buffer_thr
    add  x0, x0, :lo12:buffer_thr
    bl   parse_hex
    ands x13, x0, #1
    b.eq voltage_ok
    mov  x20, #1
    b    throttle_done
voltage_ok:
    mov  x20, #0
throttle_done:

    // ----------------
    // 3. Fréquence CPU
    // ----------------
    mov  x18, #-1                  // par défaut : absent
    adrp x0, filepath_freq
    add  x0, x0, :lo12:filepath_freq
    adrp x1, buffer_freq
    add  x1, x1, :lo12:buffer_freq
    mov  x2, #16
    bl   read_file
    cmp  x0, #0
    blt  freq_done

    adrp x0, buffer_freq
    add  x0, x0, :lo12:buffer_freq
    bl   parse_uint
    mov  x16, x0                   // valeur en kHz

    mov  x17, #1000
    udiv x18, x16, x17             // MHz entiers
    msub x19, x18, x17, x16
    mov  x17, #100
    udiv x21, x19, x17             // dixièmes
freq_done:

    // ---------------
    // 4. Load average
    // ---------------
    mov  x27, #0
    adrp x0, filepath_loadavg
    add  x0, x0, :lo12:filepath_loadavg
    adrp x1, buffer_load
    add  x1, x1, :lo12:buffer_load
    mov  x2, #64
    bl   read_file
    cmp  x0, #4
    blt  load_done
    mov  x27, #1
load_done:

    // -----------------------------------
    // 5. Utilisation CPU (via /proc/stat)
    // -----------------------------------
    adrp x0, filepath_stat
    add  x0, x0, :lo12:filepath_stat
    adrp x1, buffer_stat
    add  x1, x1, :lo12:buffer_stat
//    mov  x2, #256
    mov  x2, BUFFER_STAT_SIZE
    bl   read_file
    cmp  x0, #0
    blt  skip_cpu_stat

    adrp x0, buffer_stat
    add  x0, x0, :lo12:buffer_stat
    mov  x1, x0
    // chercher "cpu "
find_cpu:
    ldrb w2, [x1], #1
    cbz  w2, skip_cpu_stat
    cmp  w2, #'c'
    b.ne find_cpu
    ldrb w2, [x1], #1
    cmp  w2, #'p'
    b.ne find_cpu
    ldrb w2, [x1], #1
    cmp  w2, #'u'
    b.ne find_cpu
    ldrb w2, [x1], #1
    cmp  w2, #' '
    b.ne find_cpu
    // maintenant x1 pointe après l'espace
skip_spaces:
    ldrb w2, [x1], #1
    cmp  w2, #' '
    b.eq skip_spaces
    sub  x1, x1, #1               // reculer sur le premier chiffre

    // lire 8 nombres
    sub  sp, sp, #64
    mov  x4, sp
    mov  x2, #0                   // compteur
parse_stat_numbers:
    mov  x0, x1
    bl   parse_uint
    str  x0, [x4, x2, lsl #3]
    add  x2, x2, #1
    cmp  x2, #8
    b.ge stat_done
    // sauter espaces et retour chariot
skip_to_next:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq skip_to_next
    cmp  w5, #'\n'
    b.eq stat_done
    cmp  w5, #0
    b.eq stat_done
    sub  x1, x1, #1
    b    parse_stat_numbers
stat_done:
    // charger les 8 valeurs
    ldr  x3, [sp, #0]
    ldr  x4, [sp, #8]
    ldr  x5, [sp, #16]
    ldr  x6, [sp, #24]
    ldr  x7, [sp, #32]
    ldr  x8, [sp, #40]
    ldr  x9, [sp, #48]
    ldr  x10, [sp, #56]
    add  sp, sp, #64

    // calcul total
    add  x11, x3, x4
    add  x11, x11, x5
    add  x11, x11, x6
    add  x11, x11, x7
    add  x11, x11, x8
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

    sub  x14, x6, x12             // delta idle
    sub  x15, x11, x13            // delta total
    cbz  x15, cpu_stat_done
    sub  x16, x15, x14            // temps actif
    mov  x17, #100
    mul  x16, x16, x17
    udiv x22, x16, x15

    // mise à jour des précédents
    adrp x0, prev_idle
    add  x0, x0, :lo12:prev_idle
    str  x6, [x0]
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
    str  x6, [x0]
    adrp x0, prev_total
    add  x0, x0, :lo12:prev_total
    str  x11, [x0]
    adrp x0, first_stat
    add  x0, x0, :lo12:first_stat
    str  xzr, [x0]
    mov  x22, #0
cpu_stat_done:
skip_cpu_stat:

    // ------------------------------
    // 6. Mémoire RAM (/proc/meminfo)
    // ------------------------------
    mov  x23, #-1                  // par défaut : indisponible
    adrp x0, filepath_meminfo
    add  x0, x0, :lo12:filepath_meminfo
    adrp x1, buffer_meminfo
    add  x1, x1, :lo12:buffer_meminfo
    //mov  x2, #1024 // keep this line for memo
    mov  x2, BUFFER_MEMINFO_SIZE
    bl   read_file
    cmp  x0, #20
    blt  mem_skip

    adrp x0, buffer_meminfo
    add  x0, x0, :lo12:buffer_meminfo
    mov  x1, x0
    mov  x2, #0                    // MemTotal
    mov  x3, #0                    // MemAvailable

    // chercher "MemTotal:"
search_total:
    ldrb w5, [x1], #1
    cbz  w5, mem_done_parse
    cmp  w5, #'M'
    b.ne search_total
    ldrb w5, [x1], #1
    cmp  w5, #'e'
    b.ne search_total
    ldrb w5, [x1], #1
    cmp  w5, #'m'
    b.ne search_total
    ldrb w5, [x1], #1
    cmp  w5, #'T'
    b.ne search_total
    ldrb w5, [x1], #1
    cmp  w5, #'o'
    b.ne search_total
    ldrb w5, [x1], #1
    cmp  w5, #'t'
    b.ne search_total
    ldrb w5, [x1], #1
    cmp  w5, #'a'
    b.ne search_total
    ldrb w5, [x1], #1
    cmp  w5, #'l'
    b.ne search_total
    ldrb w5, [x1], #1
    cmp  w5, #':'
    b.ne search_total
    // sauter les espaces
skip_spaces_total:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq skip_spaces_total
    sub  x1, x1, #1                // revenir sur le premier chiffre
    mov  x0, x1
    bl   parse_uint
    mov  x2, x0                    // MemTotal
    mov  x1, x1                    // pointeur après le nombre

    // chercher "MemAvailable:"
search_available:
    ldrb w5, [x1], #1
    cbz  w5, mem_done_parse
    cmp  w5, #'M'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'e'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'m'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'A'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'v'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'a'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'i'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'l'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'a'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'b'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'l'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #'e'
    b.ne search_available
    ldrb w5, [x1], #1
    cmp  w5, #':'
    b.ne search_available
    // sauter les espaces
skip_spaces_avail:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq skip_spaces_avail
    sub  x1, x1, #1
    mov  x0, x1
    bl   parse_uint
    mov  x3, x0                    // MemAvailable

    // calcul pourcentage utilisé
    sub  x4, x2, x3                 // utilisé
    mov  x5, #100
    mul  x4, x4, x5
    udiv x23, x4, x2                // pourcentage dans x23
mem_done_parse:
mem_skip:

    // -----------------
    // 7. Horodatage UTC
    // -----------------
    mov  x0, #0
    adrp x1, timespec
    add  x1, x1, :lo12:timespec
    mov  x8, #SYS_CLOCK_GETTIME
    svc  #0

    adrp x3, timespec
    add  x3, x3, :lo12:timespec
    ldr  x4, [x3]

    movz x5, #0x5180
    movk x5, #0x1, lsl #16     // 86400

    mov  x6, #3600
    mov  x7, #60
    mov  x14, #10

    udiv x8, x4, x5
    msub x4, x8, x5, x4

    udiv x8, x4, x6
    msub x4, x8, x6, x4
    mov  x9, x8                // heures

    udiv x8, x4, x7
    msub x4, x8, x7, x4
    mov  x10, x8               // minutes

    mov  x11, x4               // secondes

    adrp x12, timebuf
    add  x12, x12, :lo12:timebuf
    mov  x2, x12               // pointeur dans timebuf

    // Cyan
    adrp x0, str_cyan
    add  x0, x0, :lo12:str_cyan
    bl   copy_str

    // '[' // début de ligne : crochet ouvert
    mov  w13, '['
    strb w13, [x2], #1

    // HH
    udiv x13, x9, x14
    msub x9, x13, x14, x9
    add  w13, w13, '0'
    strb w13, [x2], #1
    add  w9, w9, '0'
    strb w9, [x2], #1

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

    // " UTC] "
    adrp x0, str_utc
    add  x0, x0, :lo12:str_utc
    bl   copy_str

    // Reset
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

    // Sauvegarder la nouvelle position
    mov  x12, x2

    // Écrire l'heure
    adrp x15, timebuf
    add  x15, x15, :lo12:timebuf
    sub  x16, x12, x15
    mov  x0, #1
    mov  x1, x15
    mov  x2, x16
    mov  x8, #SYS_WRITE
    svc  #0

    // ----------------------------------------------
    // 8. Construction de la ligne de sortie (outbuf)
    // ----------------------------------------------
    adrp x2, outbuf
    add  x2, x2, :lo12:outbuf

    // Effacer outbuf (512 octets)
    // mov  x9, #64
    
    // Effacer outbuf dynamiquement selon la constante
    mov  x9, #(OUTPUT_BUFFER_SIZE / 8) // Calcule 32 itérations pour 256 octets

    mov  x10, #0
    mov  x11, x2
clear_outbuf:
    str  x10, [x11], #8
    subs x9, x9, #1
    b.ne clear_outbuf

    adrp x2, outbuf
    add  x2, x2, :lo12:outbuf

    // Restaurer les valeurs de température sauvegardées
    mov x6, x24
    mov x9, x25                  // utiliser x9 pour les dixièmes (préserve x8)

    // ---- Température CPU ----

// // Ajout d'un espace avant le premier champ
//    mov  w3, ' '
//    strb w3, [x2], #1

    // couleur selon température
    mov  x0, x6
    cmp  x0, #50
    b.lt temp_green
    cmp  x0, #65
    b.lt temp_yellow
    cmp  x0, #80
    b.lt temp_orange
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    b    temp_color_done
temp_green:
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str
    b    temp_color_done
temp_yellow:
    adrp x0, str_yellow
    add  x0, x0, :lo12:str_yellow
    bl   copy_str
    b    temp_color_done
temp_orange:
    adrp x0, str_orange
    add  x0, x0, :lo12:str_orange
    bl   copy_str
temp_color_done:

.if SHOW_THERMO == 1
    adrp x0, str_thermo
    add  x0, x0, :lo12:str_thermo
    bl   copy_str
.endif

    // afficher la température
    mov  x0, x6
    bl   uint_to_str
    mov  w3, '.'
    strb w3, [x2], #1
    add  w3, w9, '0'
    strb w3, [x2], #1
    adrp x0, str_celsius
    add  x0, x0, :lo12:str_celsius
    bl   copy_str

    // reset couleur
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

    // padding colonne température
    mov x0, #COL_TEMP_WIDTH
    bl pad_to_width

    // espace APRÈS la colonne température
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    // ---- Fréquence CPU (si disponible) ----
    cmp  x18, #-1
    b.eq skip_freq

    // "F:"
.if SHOW_FREQ == 1
    adrp x0, str_freq
    add  x0, x0, :lo12:str_freq
    bl   copy_str
.endif

    // couleur selon fréquence
    // couleur via table
    bl   select_cpu_color     // x18 = MHz → x0 = pointeur couleur
    bl   copy_str             // applique la couleur dans outbuf

    // afficher la fréquence
    mov  x0, x18
    bl   uint_to_str
    mov  w3, '.'
    strb w3, [x2], #1
    add  w3, w21, '0'
    strb w3, [x2], #1

    // padding colonne fréquence
    mov x0, #COL_FREQ_WIDTH
    bl pad_to_width

    // espace APRÈS la colonne fréquence
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    // "MHz" (ASCII pur)
    adrp x0, str_mhz
    add  x0, x0, :lo12:str_mhz
    bl   copy_str

    // reset couleur
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

skip_freq:

    // ---- Utilisation CPU (load) ----
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str
    adrp x0, str_load
    add  x0, x0, :lo12:str_load
    bl   copy_str

    // couleur selon x22
    mov  x0, x22
    cmp  x0, #25
    b.lt cpu_green
    cmp  x0, #50
    b.lt cpu_yellow
    cmp  x0, #75
    b.lt cpu_orange
    // rouge
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    b    cpu_color_done
cpu_green:
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str
    b    cpu_color_done
cpu_yellow:
    adrp x0, str_yellow
    add  x0, x0, :lo12:str_yellow
    bl   copy_str
    b    cpu_color_done
cpu_orange:
    adrp x0, str_orange
    add  x0, x0, :lo12:str_orange
    bl   copy_str
cpu_color_done:

    // afficher le pourcentage CPU
    mov  x0, x22
    bl   uint_to_str
    adrp x0, str_percent
    add  x0, x0, :lo12:str_percent
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

    // padding colonne CPU
    mov x0, #COL_CPU_WIDTH
    bl pad_to_width

    // ---- Mémoire RAM ----
    cmp  x23, #-1
    b.eq skip_ram
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str
    adrp x0, str_ram
    add  x0, x0, :lo12:str_ram
    bl   copy_str

    // couleur selon x23
    mov  x0, x23
    cmp  x0, #50
    b.lt ram_green
    cmp  x0, #80
    b.lt ram_yellow
    // rouge
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    b    ram_pct_display
ram_green:
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str
    b    ram_pct_display
ram_yellow:
    adrp x0, str_yellow
    add  x0, x0, :lo12:str_yellow
    bl   copy_str
ram_pct_display:
    mov  x0, x23
    bl   uint_to_str
    adrp x0, str_percent
    add  x0, x0, :lo12:str_percent
    bl   copy_str
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

    // padding colonne RAM
    mov x0, #COL_RAM_WIDTH
    bl pad_to_width

skip_ram:

    // ---- Under‑voltage ----
    cmp  x20, #1
    b.eq under_voltage
    cmp  x20, #0
    b.eq voltage_normal
    b    skip_voltage
under_voltage:
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
    b    skip_voltage
voltage_normal:
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
skip_voltage:

    // padding colonne UV
    mov x0, #COL_UV_WIDTH
    bl pad_to_width

    // ---- Load averages ----
    cmp  x27, #1
    b.ne skip_loadavg
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    // 1m
    adrp x0, str_color_1m
    add  x0, x0, :lo12:str_color_1m
    bl   copy_str
    adrp x0, str_1m
    add  x0, x0, :lo12:str_1m
    bl   copy_str
    adrp x0, buffer_load
    add  x0, x0, :lo12:buffer_load
copy_1m:
    ldrb w4, [x0], #1
    cmp  w4, #' '
    b.eq after_1m
    cmp  w4, #0
    b.eq after_1m
    cmp  w4, #'\n'
    b.eq after_1m
    strb w4, [x2], #1
    b    copy_1m
after_1m:

    // padding colonne LA1
    mov x0, #COL_LA_WIDTH
    bl pad_to_width

    // 5m
    adrp x0, str_color_5m
    add  x0, x0, :lo12:str_color_5m
    bl   copy_str
    adrp x0, str_5m
    add  x0, x0, :lo12:str_5m
    bl   copy_str
    // trouver le deuxième nombre
    adrp x0, buffer_load
    add  x0, x0, :lo12:buffer_load
    // sauter le premier nombre et l'espace
    mov  x4, #0
skip_first:
    ldrb w5, [x0], #1
    cmp  w5, #' '
    b.ne skip_first
    // maintenant on est sur l'espace, on le saute
skip_spaces_after_first:
    ldrb w5, [x0], #1
    cmp  w5, #' '
    b.eq skip_spaces_after_first
    // on a le premier caractère du deuxième nombre, reculer d'un
    sub x0, x0, #1
    // copier le deuxième nombre
copy_5m:
    ldrb w4, [x0], #1
    cmp  w4, #' '
    b.eq after_5m
    cmp  w4, #0
    b.eq after_5m
    cmp  w4, #'\n'
    b.eq after_5m
    strb w4, [x2], #1
    b    copy_5m
after_5m:
    // padding colonne LA2
    mov x0, #COL_LA_WIDTH
    bl pad_to_width

    // 15m
    adrp x0, str_color_15m
    add  x0, x0, :lo12:str_color_15m
    bl   copy_str
    adrp x0, str_15m
    add  x0, x0, :lo12:str_15m
    bl   copy_str
    // trouver le troisième nombre
    adrp x0, buffer_load
    add  x0, x0, :lo12:buffer_load
    // sauter les deux premiers nombres et espaces
    mov  x4, #0
    // sauter premier nombre et espace
skip_first_again:
    ldrb w5, [x0], #1
    cmp  w5, #' '
    b.ne skip_first_again
skip_spaces_after_first_again:
    ldrb w5, [x0], #1
    cmp  w5, #' '
    b.eq skip_spaces_after_first_again
    // maintenant on est sur le premier caractère du deuxième nombre, on le saute
skip_second:
    ldrb w5, [x0], #1
    cmp  w5, #' '
    b.ne skip_second
skip_spaces_after_second:
    ldrb w5, [x0], #1
    cmp  w5, #' '
    b.eq skip_spaces_after_second
    // on a le premier caractère du troisième nombre, reculer d'un
    sub x0, x0, #1
    // copier le troisième nombre
copy_15m:
    ldrb w4, [x0], #1
    cmp  w4, #' '
    b.eq after_15m
    cmp  w4, #0
    b.eq after_15m
    cmp  w4, #'\n'
    b.eq after_15m
    strb w4, [x2], #1
    b    copy_15m
after_15m:
    // pas d'espace après

// padding inutil puisque fin de ligne
// padding colonne LA3
//mov x0, #COL_LA_WIDTH
//bl pad_to_width

//adrp x0, str_space
//bl copy_str

skip_loadavg:

    // ---- Fin de ligne ----
    mov  w3, '\n'
    strb w3, [x2], #1

    // Écrire la ligne complète
    adrp x3, outbuf
    add  x3, x3, :lo12:outbuf
    sub  x12, x2, x3
    mov  x0, #1
    mov  x1, x3
    mov  x2, x12
    mov  x8, #SYS_WRITE
    svc  #0

    // ---- Pause 1 seconde ----
    adrp x0, sleep_ts
    add  x0, x0, :lo12:sleep_ts
    mov  x1, #0
    mov  x8, #SYS_NANOSLEEP
    svc  #0

    b loop

// ------------------------------------------------------
// select_cpu_color : x18 = MHz → x0 = pointeur couleur
// ------------------------------------------------------
// Entrée : x18 = fréquence en MHz
// Sortie : x0  = pointeur vers chaîne ANSI

select_cpu_color:
    adrp x3, cpu_color_table
    add  x3, x3, :lo12:cpu_color_table
    adrp x1, cpu_color_table_end
    add  x1, x1, :lo12:cpu_color_table_end

1:  cmp  x3, x1
    b.ge 3f                       // Fin de table -> fallback rouge

    ldr  x0, [x3]                 // x0 = fréquence seuil de la table
    cmp  x18, x0
    blt  2f                       // Si freq actuelle < seuil, on a trouvé la couleur

    add  x3, x3, #16              // Entrée suivante (2 quads = 16 octets)
    b    1b

2:  ldr  x0, [x3, #8]             // Charge le pointeur str_XXXXMHz
    ret

3:  adrp x0, str_red              // Fallback si > 1800MHz
    add  x0, x0, :lo12:str_red
    ret

// -------------------------------------------------------------------
// Fin du programme
// -------------------------------------------------------------------
_exit: // jamais exécuté ici - le programme s'interrompt via ctrl-C
    mov  x0, #0
    mov  x8, #SYS_EXIT
    svc  #0
