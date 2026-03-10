/*
 * ======================================================================================
 * Fichier     : monitor_temp.s
 * Date        : 2026-03-09
 * Auteur      : /B4SH 😎
 * --------------------------------------------------------------------------------------
 * LANGAGE     : ASSEMBLEUR AArch64 (ARMv8-A)
 * DESCRIPTION : Monitoring système temps réel pour Raspberry Pi 4B, écrit 
 * exclusivement en assembleur. Aucun langage de haut niveau utilisé.
 * ======================================================================================
 * * Fonctionnalités (sortie terminal) :
 * - 🕒 Heure UTC [Cyan]
 * - 🌡️ Température CPU [Jaune]
 * - ⚡ Fréquence CPU [Bleu]
 * - 🔋 Statut sous-tension [Vert/Rouge]
 * * Spécifications techniques :
 * - ABI : Appels systèmes Linux (ex: SYS_OPENAT = 56)
 * - Liaison : Aucune (nostdlib, statique)
 * * Compilation :
 * $ as -o monitor_temp.o monitor_temp.s
 * $ gcc -nostdlib -static -o monitor-temp-ASM monitor_temp.o
 * $ strip monitor-temp-ASM
 * * Just for fun ! 😎
 * ======================================================================================
 */


.global _start

    .equ SYS_OPENAT,         56
    .equ SYS_READ,           63
    .equ SYS_WRITE,          64
    .equ SYS_CLOSE,          57
    .equ SYS_NANOSLEEP,     101
    .equ SYS_EXIT,           93
    .equ SYS_CLOCK_GETTIME, 113

    .section .data

filepath_temp:
    .asciz "/sys/class/thermal/thermal_zone0/temp"

filepath_throttled:
    .asciz "/sys/devices/platform/soc/soc:firmware/get_throttled"

filepath_freq:
    .asciz "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"

buffer:
    .space 16          // température
buffer_thr:
    .space 16          // throttled
buffer_freq:
    .space 16          // fréquence

outbuf:
    .space 512         // assez grand pour tout

timebuf:
    .space 128

sleep_ts:
    .quad 2
    .quad 0

    .balign 16
timespec:
    .quad 0
    .quad 0

    .section .text

// -------------------------------------------------------------------
// Macro (ou plutôt fonction) pour convertir une chaîne décimale en entier
// Entrée : x1 = adresse de la chaîne (terminée par non-chiffre)
// Sortie : x0 = valeur entière
// Utilise x2, x3
// -------------------------------------------------------------------
// (On peut l'utiliser pour la fréquence, mais on va faire inline pour rester simple)

_start:

loop:
    // -------------------------------------------------------------
    // 1. Lecture de la température
    // -------------------------------------------------------------
    mov  x0, #-100
    adrp x1, filepath_temp
    add  x1, x1, :lo12:filepath_temp
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  #0
    mov  x9, x0               // fd température

    mov  x0, x9
    adrp x1, buffer
    add  x1, x1, :lo12:buffer
    mov  x2, #16
    mov  x8, #SYS_READ
    svc  #0
    mov  x10, x0              // nb octets lus

    mov  x0, x9
    mov  x8, #SYS_CLOSE
    svc  #0

    cmp  x10, #3
    b.lt loop                 // pas assez de données

    // -------------------------------------------------------------
    // 2. Lecture de l'état de throttling (under‑voltage)
    // -------------------------------------------------------------
    mov  x0, #-100
    adrp x1, filepath_throttled
    add  x1, x1, :lo12:filepath_throttled
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  #0
    mov  x11, x0              // fd throttled

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

    // Conversion hexadécimale -> entier dans x13
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
    // under‑voltage
    mov  x20, #1
    b    voltage_done
voltage_ok:
    mov  x20, #0
    b    voltage_done

no_throttle_file:
    mov  x20, #-1

voltage_done:
    // x20 = 1 si under‑voltage, 0 si normal, -1 si fichier absent

    // -------------------------------------------------------------
    // 3. Lecture de la fréquence CPU
    // -------------------------------------------------------------
    mov  x0, #-100
    adrp x1, filepath_freq
    add  x1, x1, :lo12:filepath_freq
    mov  x2, #0
    mov  x3, #0
    mov  x8, #SYS_OPENAT
    svc  #0
    mov  x14, x0              // fd fréquence

    cmp  x14, #0
    b.lt  no_freq_file

    mov  x0, x14
    adrp x1, buffer_freq
    add  x1, x1, :lo12:buffer_freq
    mov  x2, #16
    mov  x8, #SYS_READ
    svc  #0
    mov  x15, x0              // nb octets lus

    mov  x0, x14
    mov  x8, #SYS_CLOSE
    svc  #0

    // Convertir la chaîne décimale en entier (kHz)
    adrp x1, buffer_freq
    add  x1, x1, :lo12:buffer_freq
    mov  x16, #0              // résultat
1:  ldrb w2, [x1], #1
    cmp  w2, #'0'
    b.lt 2f
    cmp  w2, #'9'
    b.gt 2f
    sub  w2, w2, #'0'
    add  x16, x16, x16, lsl #2   // *5
    lsl  x16, x16, #1            // *10
    add  x16, x16, x2
    b    1b
2:
    // x16 = fréquence en kHz
    // Convertir en MHz avec une décimale : partie entière = kHz/1000, dixième = (kHz%1000)/100
    mov  x17, #1000
    udiv x18, x16, x17        // MHz entiers
    msub x19, x18, x17, x16   // reste
    mov  x17, #100
    udiv x21, x19, x17        // dixième (0-9)
    // x18 = partie entière, x21 = dixième
    b    freq_done

no_freq_file:
    // Pas de fichier fréquence : on met un indicateur spécial (par exemple -1 dans x18)
    mov  x18, #-1

freq_done:
    // x18 = MHz entiers (ou -1 si absent), x21 = dixième (si présent)

    // -------------------------------------------------------------
    // 4. Horodatage UTC en cyan
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

    // CYAN : ESC[36m
    mov  w13, #0x1B
    strb w13, [x12], #1
    mov  w13, '['
    strb w13, [x12], #1
    mov  w13, '3'
    strb w13, [x12], #1
    mov  w13, '6'
    strb w13, [x12], #1
    mov  w13, 'm'
    strb w13, [x12], #1

    // '['
    mov  w13, '['
    strb w13, [x12], #1

    // HH
    udiv x13, x9, x14
    msub x9, x13, x14, x9
    add  w13, w13, '0'
    strb w13, [x12], #1
    add  w9, w9, '0'
    strb w9, [x12], #1

    mov  w13, ':'
    strb w13, [x12], #1

    // MM
    udiv x13, x10, x14
    msub x10, x13, x14, x10
    add  w13, w13, '0'
    strb w13, [x12], #1
    add  w10, w10, '0'
    strb w10, [x12], #1

    mov  w13, ':'
    strb w13, [x12], #1

    // SS
    udiv x13, x11, x14
    msub x11, x13, x14, x11
    add  w13, w13, '0'
    strb w13, [x12], #1
    add  w11, w11, '0'
    strb w11, [x12], #1

    // " UTC]"
    mov  w13, ' '
    strb w13, [x12], #1
    mov  w13, 'U'
    strb w13, [x12], #1
    mov  w13, 'T'
    strb w13, [x12], #1
    mov  w13, 'C'
    strb w13, [x12], #1
    mov  w13, ']'
    strb w13, [x12], #1
    mov  w13, ' '
    strb w13, [x12], #1

    // RESET : ESC[0m
    mov  w13, #0x1B
    strb w13, [x12], #1
    mov  w13, '['
    strb w13, [x12], #1
    mov  w13, '0'
    strb w13, [x12], #1
    mov  w13, 'm'
    strb w13, [x12], #1

    adrp x15, timebuf
    add  x15, x15, :lo12:timebuf
    sub  x16, x12, x15

    mov  x0, #1
    mov  x1, x15
    mov  x2, x16
    mov  x8, #SYS_WRITE
    svc  #0

    // -------------------------------------------------------------
    // 5. Température en jaune (conversion précise)
    // -------------------------------------------------------------
    adrp x1, buffer
    add  x1, x1, :lo12:buffer

    // Convertir la chaîne ASCII en entier (millidegrés)
    mov  x3, #0
1:  ldrb w5, [x1], #1
    cmp  w5, #'0'
    b.lt 2f
    cmp  w5, #'9'
    b.gt 2f
    sub  w5, w5, #'0'
    add  x3, x3, x3, lsl #2   // x3 = x3*5
    lsl  x3, x3, #1           // x3 = x3*10
    add  x3, x3, x5
    b    1b
2:
    // x3 = millidegrés
    mov  x5, #1000
    udiv x6, x3, x5           // degrés entiers
    msub x7, x6, x5, x3       // reste
    mov  x5, #100
    udiv x8, x7, x5           // dixième

    // Préparer outbuf
    adrp x2, outbuf
    add  x2, x2, :lo12:outbuf

    // Effacer outbuf (512 octets) par mots de 8
    mov  x9, #64               // 64 * 8 = 512
    mov  x10, #0
    mov  x11, x2
3:  str  x10, [x11], #8
    subs x9, x9, #1
    b.ne 3b

    adrp x2, outbuf
    add  x2, x2, :lo12:outbuf

    // JAUNE : ESC[33m
    mov  w3, #0x1B
    strb w3, [x2], #1
    mov  w3, '['
    strb w3, [x2], #1
    mov  w3, '3'
    strb w3, [x2], #1
    mov  w3, '3'
    strb w3, [x2], #1
    mov  w3, 'm'
    strb w3, [x2], #1

    // Conversion partie entière (x6) en décimal (avec buffer sur pile)
    sub  sp, sp, #16
    mov  x9, sp
    mov  x10, x6
    mov  x11, #10
    mov  x12, #0
4:  udiv x13, x10, x11
    msub x14, x13, x11, x10
    add  w14, w14, '0'
    strb w14, [x9, x12]
    add  x12, x12, #1
    mov  x10, x13
    cbnz x10, 4b

    add  x9, x9, x12
    sub  x9, x9, #1
5:  ldrb w10, [x9], #-1
    strb w10, [x2], #1
    subs x12, x12, #1
    b.ne 5b

    add  sp, sp, #16

    // Point décimal
    mov  w3, '.'
    strb w3, [x2], #1

    // Dixième
    add  w3, w8, '0'
    strb w3, [x2], #1

    // Espace
    mov  w3, ' '
    strb w3, [x2], #1

    // Symbole °C (toujours en jaune)
    mov  w3, 0xC2
    strb w3, [x2], #1
    mov  w3, 0xB0
    strb w3, [x2], #1
    mov  w3, 'C'
    strb w3, [x2], #1

    // -------------------------------------------------------------
    // 6. Fréquence CPU en bleu (si disponible)
    // -------------------------------------------------------------
    cmp  x18, #-1
    b.eq skip_freq

    // Espace avant la fréquence
    mov  w3, ' '
    strb w3, [x2], #1

    // BLEU : ESC[34m
    mov  w3, #0x1B
    strb w3, [x2], #1
    mov  w3, '['
    strb w3, [x2], #1
    mov  w3, '3'
    strb w3, [x2], #1
    mov  w3, '4'
    strb w3, [x2], #1
    mov  w3, 'm'
    strb w3, [x2], #1

    // Convertir la partie entière (x18) en décimal (MHz)
    sub  sp, sp, #16
    mov  x9, sp
    mov  x10, x18
    mov  x11, #10
    mov  x12, #0
6:  udiv x13, x10, x11
    msub x14, x13, x11, x10
    add  w14, w14, '0'
    strb w14, [x9, x12]
    add  x12, x12, #1
    mov  x10, x13
    cbnz x10, 6b

    add  x9, x9, x12
    sub  x9, x9, #1
7:  ldrb w10, [x9], #-1
    strb w10, [x2], #1
    subs x12, x12, #1
    b.ne 7b

    add  sp, sp, #16

    // Point décimal
    mov  w3, '.'
    strb w3, [x2], #1

    // Dixième (x21)
    add  w3, w21, '0'
    strb w3, [x2], #1

    // Espace puis "MHz"
    mov  w3, ' '
    strb w3, [x2], #1
    mov  w3, 'M'
    strb w3, [x2], #1
    mov  w3, 'H'
    strb w3, [x2], #1
    mov  w3, 'z'
    strb w3, [x2], #1

    // Reset couleur (on remettra le reset global à la fin)
    // On ne reset pas ici pour que le voltage ait sa propre couleur

skip_freq:

    // -------------------------------------------------------------
    // 7. Indicateur de sous‑tension (voltage) selon x20
    // -------------------------------------------------------------
    cmp  x20, #1
    b.eq under_voltage
    cmp  x20, #0
    b.eq voltage_normal
    // fichier absent : on ne fait rien
    b    skip_voltage

under_voltage:
    // Espace avant le message
    mov  w3, ' '
    strb w3, [x2], #1
    // ROUGE : ESC[31m
    mov  w3, #0x1B
    strb w3, [x2], #1
    mov  w3, '['
    strb w3, [x2], #1
    mov  w3, '3'
    strb w3, [x2], #1
    mov  w3, '1'
    strb w3, [x2], #1
    mov  w3, 'm'
    strb w3, [x2], #1

    // "[UNDERVOLT]"
    mov  w3, '['
    strb w3, [x2], #1
    mov  w3, 'U'
    strb w3, [x2], #1
    mov  w3, 'N'
    strb w3, [x2], #1
    mov  w3, 'D'
    strb w3, [x2], #1
    mov  w3, 'E'
    strb w3, [x2], #1
    mov  w3, 'R'
    strb w3, [x2], #1
    mov  w3, 'V'
    strb w3, [x2], #1
    mov  w3, 'O'
    strb w3, [x2], #1
    mov  w3, 'L'
    strb w3, [x2], #1
    mov  w3, 'T'
    strb w3, [x2], #1
    mov  w3, ']'
    strb w3, [x2], #1

    b    skip_voltage

voltage_normal:
    // Espace avant le message
    mov  w3, ' '
    strb w3, [x2], #1
    // VERT : ESC[32m
    mov  w3, #0x1B
    strb w3, [x2], #1
    mov  w3, '['
    strb w3, [x2], #1
    mov  w3, '3'
    strb w3, [x2], #1
    mov  w3, '2'
    strb w3, [x2], #1
    mov  w3, 'm'
    strb w3, [x2], #1

    // "[OK]"
    mov  w3, '['
    strb w3, [x2], #1
    mov  w3, 'O'
    strb w3, [x2], #1
    mov  w3, 'K'
    strb w3, [x2], #1
    mov  w3, ']'
    strb w3, [x2], #1

    b    skip_voltage

skip_voltage:
    // Reset global (ESC[0m)
    mov  w3, #0x1B
    strb w3, [x2], #1
    mov  w3, '['
    strb w3, [x2], #1
    mov  w3, '0'
    strb w3, [x2], #1
    mov  w3, 'm'
    strb w3, [x2], #1

    // Saut de ligne
    mov  w3, '\n'
    strb w3, [x2], #1

    // Calcul de la longueur et écriture
    adrp x3, outbuf
    add  x3, x3, :lo12:outbuf
    sub  x12, x2, x3
    mov  x0, #1
    mov  x1, x3
    mov  x2, x12
    mov  x8, #SYS_WRITE
    svc  #0

    // -------------------------------------------------------------
    // 8. Pause de 2 secondes
    // -------------------------------------------------------------
    adrp x0, sleep_ts
    add  x0, x0, :lo12:sleep_ts
    mov  x1, #0
    mov  x8, #SYS_NANOSLEEP
    svc  #0

    b loop

_exit:
    mov x0, #0
    mov x8, #SYS_EXIT
    svc #0
