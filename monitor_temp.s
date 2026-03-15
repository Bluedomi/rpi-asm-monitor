/*
 * ======================================================================================
 * Fichier     : monitor_temp.s
 * Version     : 1.9
 * Date        : 2026-03-14
 * Auteur      : /B4SH 😎
 * --------------------------------------------------------------------------------------
 * LANGAGE     : ASSEMBLEUR AArch64 (ARMv8-A)
 * DESCRIPTION : Monitoring système temps réel pour Raspberry Pi 4B
 * * Compilation :
 * $ as -o monitor_temp.o monitor_temp.s
 * $ gcc -nostdlib -static -o monitor-temp-ASM monitor_temp.o
 * $ strip monitor-temp-ASM
 * * Just for fun ! 😎
 * ======================================================================================
 */

// .set SHOW_FREQ, 1 // Commenter = désactiver // old fashion
.equ SHOW_FREQ,     1  // 1 pour activer, 0 pour désactiver
.equ SHOW_THERMO,   1

.global _start

    .equ SYS_OPENAT,         56
    .equ SYS_READ,           63
    .equ SYS_WRITE,          64
    .equ SYS_CLOSE,          57
    .equ SYS_NANOSLEEP,     101
    .equ SYS_EXIT,           93
    .equ SYS_CLOCK_GETTIME, 113
    .equ SYS_SYSINFO,       179

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

//str_freq:       .asciz "Freq:"
str_freq:       .asciz "F:"
str_load:       .asciz "L:"
str_ram:        .asciz "M:"
str_mhz:        .asciz "MHz"
str_thermo:     .asciz "🌡️ "
str_celsius:    .asciz "°C"
str_ok:         .asciz "⚡️✅"
str_undervolt:  .asciz "⚡️❌"
str_space:      .asciz " "
str_percent:    .asciz "%"
str_1m:         .asciz "1m:"
str_5m:         .asciz "5m:"
str_15m:        .asciz "15m:"
str_utc:        .asciz " UTC] "

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
    .space 256
buffer_meminfo:
    .space 1024

outbuf:
    .space 512
timebuf:
    .space 128

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

    .section .text

// -------------------------------------------------------------------
// copy_str : copie une chaîne ASCIIZ de x0 vers (x2), met à jour x2
// -------------------------------------------------------------------
copy_str:
    ldrb w1, [x0], #1
    cbz  w1, 1f
    strb w1, [x2], #1
    b    copy_str
1:  ret

// -------------------------------------------------------------------
// Programme principal
// -------------------------------------------------------------------
_start:

loop:
    // -------------------------------------------------------------
    // 1. Lecture température CPU
    // -------------------------------------------------------------
    mov  x0, #-100
    adrp x1, filepath_temp
    add  x1, x1, :lo12:filepath_temp
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  #0
    mov  x9, x0

    mov  x0, x9
    adrp x1, buffer
    add  x1, x1, :lo12:buffer
    mov  x2, #16
    mov  x8, #SYS_READ
    svc  #0
    mov  x10, x0

    mov  x0, x9
    mov  x8, #SYS_CLOSE
    svc  #0

    cmp  x10, #3
    b.lt loop

    // -------------------------------------------------------------
    // 2. Lecture throttling
    // -------------------------------------------------------------
    mov  x0, #-100
    adrp x1, filepath_throttled
    add  x1, x1, :lo12:filepath_throttled
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  #0
    mov  x11, x0

    cmp  x11, #0
    b.lt  no_throttle_file

    mov  x0, x11
    adrp x1, buffer_thr
    add  x1, x1, :lo12:buffer_thr
    mov  x2, #16
    mov  x8, #SYS_READ
    svc  #0
    mov  x12, x0

    mov  x0, x11
    mov  x8, #SYS_CLOSE
    svc  #0

    adrp x1, buffer_thr
    add  x1, x1, :lo12:buffer_thr
    mov  x13, #0
parse_throttle:
    ldrb w2, [x1], #1
    cmp  w2, #'0'
    b.lt  end_parse
    cmp  w2, #'9'
    b.le digit
    cmp  w2, #'A'
    b.lt end_parse
    cmp  w2, #'F'
    b.le hex_upper
    cmp  w2, #'a'
    b.lt end_parse
    cmp  w2, #'f'
    b.le hex_lower
    b    end_parse
digit:
    sub  w2, w2, #'0'
    b    store
hex_upper:
    sub  w2, w2, #'A'
    add  w2, w2, #10
    b    store
hex_lower:
    sub  w2, w2, #'a'
    add  w2, w2, #10
store:
    lsl  x13, x13, #4
    add  x13, x13, x2
    b    parse_throttle
end_parse:
    ands x13, x13, #1
    b.eq voltage_ok
    mov  x20, #1
    b    voltage_done
voltage_ok:
    mov  x20, #0
    b    voltage_done

no_throttle_file:
    mov  x20, #-1

voltage_done:
    // x20 = 1 (under‑voltage), 0 (OK), -1 (inconnu)

    // -------------------------------------------------------------
    // 3. Lecture fréquence CPU
    // -------------------------------------------------------------
    mov  x0, #-100
    adrp x1, filepath_freq
    add  x1, x1, :lo12:filepath_freq
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  #0
    mov  x14, x0

    cmp  x14, #0
    b.lt  no_freq_file

    mov  x0, x14
    adrp x1, buffer_freq
    add  x1, x1, :lo12:buffer_freq
    mov  x2, #16
    mov  x8, #SYS_READ
    svc  #0
    mov  x15, x0

    mov  x0, x14
    mov  x8, #SYS_CLOSE
    svc  #0

    adrp x1, buffer_freq
    add  x1, x1, :lo12:buffer_freq
    mov  x16, #0
freq_parse:
    ldrb w2, [x1], #1
    cmp  w2, #'0'
    b.lt freq_done_parse
    cmp  w2, #'9'
    b.gt freq_done_parse
    sub  w2, w2, #'0'
    uxtw x2, w2                    // CORRIGÉ : extension
    add  x16, x16, x16, lsl #2
    lsl  x16, x16, #1
    add  x16, x16, x2
    b    freq_parse
freq_done_parse:
    mov  x17, #1000
    udiv x18, x16, x17
    msub x19, x18, x17, x16
    mov  x17, #100
    udiv x21, x19, x17
    b    freq_done

no_freq_file:
    mov  x18, #-1

freq_done:
    // x18 = MHz entiers, x21 = dixième

    // -------------------------------------------------------------
    // 4. Lecture loadavg (/proc/loadavg)
    // -------------------------------------------------------------
    mov  x0, #-100
    adrp x1, filepath_loadavg
    add  x1, x1, :lo12:filepath_loadavg
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  #0
    mov  x25, x0

    cmp  x25, #0
    b.lt load_fail

    mov  x0, x25
    adrp x1, buffer_load
    add  x1, x1, :lo12:buffer_load
    mov  x2, #64
    mov  x8, #SYS_READ
    svc  #0
    mov  x26, x0

    mov  x0, x25
    mov  x8, #SYS_CLOSE
    svc  #0

    cmp  x26, #4
    b.lt load_fail

    mov  x27, #1
    b    load_done

load_fail:
    mov  x27, #0

load_done:

    // -------------------------------------------------------------
    // 5. Lecture utilisation CPU (/proc/stat)
    // -------------------------------------------------------------
    mov  x22, #0
    mov  x0, #-100
    adrp x1, filepath_stat
    add  x1, x1, :lo12:filepath_stat
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  #0
    mov  x28, x0

    cmp  x28, #0
    b.lt  skip_cpu_stat

    mov  x0, x28
    adrp x1, buffer_stat
    add  x1, x1, :lo12:buffer_stat
    mov  x2, #256
    mov  x8, #SYS_READ
    svc  #0
    mov  x29, x0

    mov  x0, x28
    mov  x8, #SYS_CLOSE
    svc  #0

    adrp x1, buffer_stat
    add  x1, x1, :lo12:buffer_stat

    // Chercher le début des nombres après "cpu "
    mov  x2, #0
    mov  x3, #0
    mov  x4, #0

    sub  sp, sp, #64
    mov  x5, sp

skip_header:
    ldrb w0, [x1], #1
    cmp  w0, #' '
    b.ne skip_header

parse_stat_loop:
    ldrb w0, [x1], #1
    cmp  w0, #0
    b.eq end_stat_parse
    cmp  w0, #'\n'
    b.eq end_stat_parse
    cmp  w0, #' '
    b.eq space_found
    cmp  w0, #'0'
    b.lt parse_stat_loop
    cmp  w0, #'9'
    b.gt parse_stat_loop
    sub  w0, w0, #'0'
    uxtw x0, w0                    // CORRIGÉ : extension
    cmp  x4, #0
    b.eq new_number
    ldr  x6, [x5, x2, lsl #3]
    add  x6, x6, x6, lsl #2
    lsl  x6, x6, #1
    add  x6, x6, x0
    str  x6, [x5, x2, lsl #3]
    b    parse_stat_loop
new_number:
    mov  x4, #1
    cmp  x2, #8
    b.ge parse_stat_loop
    mov  x6, x0
    str  x6, [x5, x2, lsl #3]
    b    parse_stat_loop
space_found:
    cmp  x4, #1
    b.ne parse_stat_loop
    mov  x4, #0
    add  x2, x2, #1
    b    parse_stat_loop

end_stat_parse:
    cmp  x4, #1
    b.ne 1f
    add  x2, x2, #1
1:
    ldr  x3, [sp, #0]
    ldr  x4, [sp, #8]
    ldr  x5, [sp, #16]
    ldr  x6, [sp, #24]
    ldr  x7, [sp, #32]
    ldr  x8, [sp, #40]
    ldr  x9, [sp, #48]
    ldr  x10, [sp, #56]
    add  sp, sp, #64

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

    sub  x14, x6, x12
    sub  x15, x11, x13
    cbz  x15, cpu_stat_done
    sub  x16, x15, x14
    mov  x17, #100
    mul  x16, x16, x17
    udiv x22, x16, x15

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

// -------------------------------------------------------------
// 6. Lecture mémoire via /proc/meminfo (corrigée avec sauvegarde dans x23)
// -------------------------------------------------------------
mov  x30, #-1               // valeur par défaut
mov  x23, #-1               // CORRIGÉ : initialisation de x23 (pourcentage RAM)
mov  x0, #-100
adrp x1, filepath_meminfo
add  x1, x1, :lo12:filepath_meminfo
mov  x2, #0
mov  x3, #0
mov  x8, #SYS_OPENAT
svc  #0
mov  x28, x0                // fd meminfo
cmp  x28, #0
b.lt mem_skip

mov  x0, x28
adrp x1, buffer_meminfo
add  x1, x1, :lo12:buffer_meminfo
mov  x2, #1024
mov  x8, #SYS_READ
svc  #0
mov  x29, x0                // nb octets lus

mov  x0, x28
mov  x8, #SYS_CLOSE
svc  #0

cmp  x29, #20
b.lt mem_skip

adrp x0, buffer_meminfo
add  x0, x0, :lo12:buffer_meminfo
mov  x1, x0
mov  x2, #0                  // MemTotal
mov  x3, #0                  // MemAvailable

// Chercher "MemTotal:"
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
    // trouvé "MemTotal:"
    // sauter les espaces
skip_spaces_total:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq skip_spaces_total
    // premier chiffre
    sub  w5, w5, #'0'
    uxtw x5, w5              // CORRIGÉ : extension
    mov  x2, x5
read_total:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq after_total
    cmp  w5, #'\n'
    b.eq after_total
    cmp  w5, #0
    b.eq after_total
    sub  w5, w5, #'0'
    uxtw x5, w5              // CORRIGÉ : extension
    add  x2, x2, x2, lsl #2  // x2 = x2 * 5
    lsl  x2, x2, #1          // x2 = x2 * 10
    add  x2, x2, x5          // ajout du nouveau chiffre
    b    read_total
after_total:
    // Maintenant chercher "MemAvailable:"
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
    // trouvé "MemAvailable:"
    // sauter les espaces
skip_spaces_avail:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq skip_spaces_avail
    // premier chiffre
    sub  w5, w5, #'0'
    uxtw x5, w5              // CORRIGÉ
    mov  x3, x5
read_avail:
    ldrb w5, [x1], #1
    cmp  w5, #' '
    b.eq after_avail
    cmp  w5, #'\n'
    b.eq after_avail
    cmp  w5, #0
    b.eq after_avail
    sub  w5, w5, #'0'
    uxtw x5, w5              // CORRIGÉ
    add  x3, x3, x3, lsl #2
    lsl  x3, x3, #1
    add  x3, x3, x5
    b    read_avail
after_avail:
    // Calcul du pourcentage
    sub  x4, x2, x3          // utilisé = total - disponible
    mov  x5, #100
    mul  x4, x4, x5
    udiv x30, x4, x2         // x30 = pourcentage utilisé
    mov  x23, x30             // CORRIGÉ : sauvegarde dans x23 (registre préservé)
mem_done_parse:
mem_skip:

    // -------------------------------------------------------------
    // 7. Horodatage UTC (cyan)
    // -------------------------------------------------------------
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
    mov  x2, x12                // x2 pointe sur timebuf

    // Cyan
    adrp x0, str_cyan
    add  x0, x0, :lo12:str_cyan
    bl   copy_str

    // '['
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

    // Sauvegarder la nouvelle position de timebuf
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

// -------------------------------------------------------------
// 8. Température CPU (avec coloration dynamique)
// -------------------------------------------------------------
adrp x1, buffer
add  x1, x1, :lo12:buffer

mov  x3, #0
temp_parse:
    ldrb w5, [x1], #1
    cmp  w5, #'0'
    b.lt temp_done
    cmp  w5, #'9'
    b.gt temp_done
    sub  w5, w5, #'0'
    uxtw x5, w5
    add  x3, x3, x3, lsl #2
    lsl  x3, x3, #1
    add  x3, x3, x5
    b    temp_parse

temp_done:
    mov  x5, #1000
    udiv x6, x3, x5        // x6 = degrés entiers
    msub x7, x6, x5, x3
    mov  x5, #100
    udiv x8, x7, x5        // x8 = dixièmes

adrp x2, outbuf
add  x2, x2, :lo12:outbuf

// Effacer outbuf (512 octets)
mov  x9, #64
mov  x10, #0
mov  x11, x2
clear_outbuf:
    str  x10, [x11], #8
    subs x9, x9, #1
    b.ne clear_outbuf

adrp x2, outbuf
add  x2, x2, :lo12:outbuf

// -------------------------------------------------------------
// Couleur dynamique selon la température (x6 = degrés entiers)
// -------------------------------------------------------------
mov  x0, x6

cmp  x0, #50
b.lt temp_green

cmp  x0, #65
b.lt temp_yellow

cmp  x0, #80
b.lt temp_orange

// Rouge (>= 80°C)
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

// Emoji thermomètre
.if SHOW_THERMO == 1
    adrp x0, str_thermo
    add  x0, x0, :lo12:str_thermo
    bl   copy_str
.endif

// -------------------------------------------------------------
// Affichage des degrés entiers
// -------------------------------------------------------------
sub  sp, sp, #16
mov  x9, sp
mov  x10, x6
mov  x11, #10
mov  x12, #0

cpu_dec_loop:
    udiv x13, x10, x11
    msub x14, x13, x11, x10
    add  w14, w14, '0'
    strb w14, [x9, x12]
    add  x12, x12, #1
    mov  x10, x13
    cbnz x10, cpu_dec_loop

add  x9, x9, x12
sub  x9, x9, #1

cpu_dec_out:
    ldrb w10, [x9], #-1
    strb w10, [x2], #1
    subs x12, x12, #1
    b.ne cpu_dec_out

add  sp, sp, #16

// ".x °C"
mov  w3, '.'
strb w3, [x2], #1
add  w3, w8, '0'
strb w3, [x2], #1

adrp x0, str_celsius
add  x0, x0, :lo12:str_celsius
bl   copy_str

// Reset couleur
adrp x0, str_reset
add  x0, x0, :lo12:str_reset
bl   copy_str

    // -------------------------------------------------------------
    // 9. Fréquence CPU en bleu (avec label "Freq:")
    // -------------------------------------------------------------
    cmp  x18, #-1
    b.eq skip_freq

    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

//.ifdef SHOW_FREQ
.if SHOW_FREQ == 1
    // Texte "Freq:"
    adrp x0, str_freq
    add  x0, x0, :lo12:str_freq
    bl   copy_str
.endif

    // -------------------------------------------------------------
    // Couleur dynamique selon la fréquence CPU (x18 = MHz)
    // -------------------------------------------------------------
    mov  x0, x18

    cmp  x0, #800
    b.lt freq_green

    cmp  x0, #1200
    b.lt freq_yellow

    cmp  x0, #1500
    b.lt freq_orange

    cmp  x0, #1800
    b.lt freq_orange_dark

    // Rouge (>= 1800 MHz)
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    b    freq_color_done

freq_green:
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str
    b    freq_color_done

freq_yellow:
    adrp x0, str_yellow
    add  x0, x0, :lo12:str_yellow
    bl   copy_str
    b    freq_color_done

freq_orange:
    adrp x0, str_orange
    add  x0, x0, :lo12:str_orange
    bl   copy_str
    b    freq_color_done

freq_orange_dark:
    // Optionnel : orange foncé (256 couleurs)
    // Sinon, réutiliser str_orange
    adrp x0, str_orange_dark
    add  x0, x0, :lo12:str_orange_dark
    bl   copy_str

freq_color_done:

    // Valeur
    sub  sp, sp, #16
    mov  x9, sp
    mov  x10, x18
    mov  x11, #10
    mov  x12, #0
freq_dec_loop:
    udiv x13, x10, x11
    msub x14, x13, x11, x10
    add  w14, w14, '0'
    strb w14, [x9, x12]
    add  x12, x12, #1
    mov  x10, x13
    cbnz x10, freq_dec_loop

    add  x9, x9, x12
    sub  x9, x9, #1
freq_dec_out:
    ldrb w10, [x9], #-1
    strb w10, [x2], #1
    subs x12, x12, #1
    b.ne freq_dec_out

    add  sp, sp, #16

    mov  w3, '.'
    strb w3, [x2], #1
    add  w3, w21, '0'
    strb w3, [x2], #1
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str
    adrp x0, str_mhz
    add  x0, x0, :lo12:str_mhz
    bl   copy_str

    // Reset
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

skip_freq:

    // -------------------------------------------------------------
    // 10. Utilisation CPU (Load:) avec couleur dynamique
    // -------------------------------------------------------------
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    // Texte "Load:"
    adrp x0, str_load
    add  x0, x0, :lo12:str_load
    bl   copy_str

//    // Choisir la couleur selon x22
//    mov  x0, x22
//    cmp  x0, #33
//    b.lt load_green
//    cmp  x0, #66
//    b.lt load_yellow
//    // >= 66% : rouge
//    adrp x0, str_red
//    add  x0, x0, :lo12:str_red
//    bl   copy_str
//    b    load_pct_display
//load_yellow:
//    adrp x0, str_yellow
//    add  x0, x0, :lo12:str_yellow
//    bl   copy_str
//    b    load_pct_display
//load_green:
//    adrp x0, str_green
//    add  x0, x0, :lo12:str_green
//    bl   copy_str
//

    // Choisir la couleur selon x22 (CPU %)
    mov  x0, x22
    cmp  x0, #25
    b.lt cpu_green

    cmp  x0, #50
    b.lt cpu_yellow

    cmp  x0, #75
    b.lt cpu_orange

    // Rouge (>= 75)
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



load_pct_display:
    // Convertir x22 en décimal
    sub  sp, sp, #16
    mov  x9, sp
    mov  x10, x22
    mov  x11, #10
    mov  x12, #0
load_pct_loop:
    udiv x13, x10, x11
    msub x14, x13, x11, x10
    add  w14, w14, '0'
    strb w14, [x9, x12]
    add  x12, x12, #1
    mov  x10, x13
    cbnz x10, load_pct_loop

    add  x9, x9, x12
    sub  x9, x9, #1
load_pct_out:
    ldrb w10, [x9], #-1
    strb w10, [x2], #1
    subs x12, x12, #1
    b.ne load_pct_out

    add  sp, sp, #16

    // "%"
    adrp x0, str_percent
    add  x0, x0, :lo12:str_percent
    bl   copy_str

    // Reset couleur
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

    // -------------------------------------------------------------
    // 11. Mémoire RAM (RAM:) avec couleur dynamique (utilise x23)
    // -------------------------------------------------------------
    cmp  x23, #-1                // CORRIGÉ : utiliser x23 au lieu de x30
    b.eq skip_ram

    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    // Texte "RAM:"
    adrp x0, str_ram
    add  x0, x0, :lo12:str_ram
    bl   copy_str

    // Choisir la couleur selon x23
    mov  x0, x23                 // CORRIGÉ
    cmp  x0, #50
    b.lt ram_green
    cmp  x0, #80
    b.lt ram_yellow
    // >= 80% : rouge
    adrp x0, str_red
    add  x0, x0, :lo12:str_red
    bl   copy_str
    b    ram_pct_display
ram_yellow:
    adrp x0, str_yellow
    add  x0, x0, :lo12:str_yellow
    bl   copy_str
    b    ram_pct_display
ram_green:
    adrp x0, str_green
    add  x0, x0, :lo12:str_green
    bl   copy_str

ram_pct_display:
    // Convertir x23 en décimal
    sub  sp, sp, #16
    mov  x9, sp
    mov  x10, x23                // CORRIGÉ
    mov  x11, #10
    mov  x12, #0
ram_pct_loop:
    udiv x13, x10, x11
    msub x14, x13, x11, x10
    add  w14, w14, '0'
    strb w14, [x9, x12]
    add  x12, x12, #1
    mov  x10, x13
    cbnz x10, ram_pct_loop

    add  x9, x9, x12
    sub  x9, x9, #1
ram_pct_out:
    ldrb w10, [x9], #-1
    strb w10, [x2], #1
    subs x12, x12, #1
    b.ne ram_pct_out

    add  sp, sp, #16

    // "%"
    adrp x0, str_percent
    add  x0, x0, :lo12:str_percent
    bl   copy_str

    // Reset couleur
    adrp x0, str_reset
    add  x0, x0, :lo12:str_reset
    bl   copy_str

skip_ram:

    // -------------------------------------------------------------
    // 12. Indicateur sous-tension
    // -------------------------------------------------------------
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

    // -------------------------------------------------------------
    // 13. Load averages
    // -------------------------------------------------------------
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

    // copier premier nombre
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
    // 1 espace après le premier nombre
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    // 5m:
    adrp x0, str_color_5m
    add  x0, x0, :lo12:str_color_5m
    bl   copy_str

    adrp x0, str_5m
    add  x0, x0, :lo12:str_5m
    bl   copy_str

    // réinitialiser le pointeur buffer_load
    adrp x0, buffer_load
    add  x0, x0, :lo12:buffer_load
    mov  x4, #0
    mov  x5, #0

    // trouver le deuxième champ
find_5m:
    ldrb w6, [x0, x5]
    add  x5, x5, #1
    cmp  w6, #' '
    b.eq find_5m
    cmp  w6, #0
    b.eq loadavg_error
    cmp  w6, #'\n'
    b.eq loadavg_error
    sub  x5, x5, #1
    add  x0, x0, x5
    b    copy_5m_start

loadavg_error:
    b    skip_loadavg

copy_5m_start:
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
    // 1 espaces après le deuxième nombre
    adrp x0, str_space
    add  x0, x0, :lo12:str_space
    bl   copy_str

    // 15m:
    adrp x0, str_color_15m
    add  x0, x0, :lo12:str_color_15m
    bl   copy_str

    adrp x0, str_15m
    add  x0, x0, :lo12:str_15m
    bl   copy_str

    // réinitialiser le pointeur buffer_load
    adrp x0, buffer_load
    add  x0, x0, :lo12:buffer_load
    mov  x4, #0
    mov  x5, #0

    // trouver le troisième champ
find_15m:
    ldrb w6, [x0, x5]
    add  x5, x5, #1
    cmp  w6, #' '
    b.eq find_15m
    cmp  w6, #0
    b.eq loadavg_error2
    cmp  w6, #'\n'
    b.eq loadavg_error2
    sub  x5, x5, #1
    add  x0, x0, x5
    b    copy_15m_start

loadavg_error2:
    b    skip_loadavg

copy_15m_start:
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
    // pas d'espaces après le dernier nombre

skip_loadavg:

    // -------------------------------------------------------------
    // 14. Fin de ligne
    // -------------------------------------------------------------
    mov  w3, '\n'
    strb w3, [x2], #1

    adrp x3, outbuf
    add  x3, x3, :lo12:outbuf
    sub  x12, x2, x3

    mov  x0, #1
    mov  x1, x3
    mov  x2, x12
    mov  x8, #SYS_WRITE
    svc  #0

    // -------------------------------------------------------------
    // 15. Pause 1 seconde
    // -------------------------------------------------------------
    adrp x0, sleep_ts
    add  x0, x0, :lo12:sleep_ts
    mov  x1, #0
    mov  x8, #SYS_NANOSLEEP
    svc  #0

    b loop

_exit:
    mov  x0, #0
    mov  x8, #SYS_EXIT
    svc  #0
