/*  The instructions a program's own code executed, for docs/measurement.md's
 *  `instructions` class: a QEMU TCG plugin, built by scripts/measure.py
 *  against the running QEMU's own plugin header.
 *
 *      -plugin count.so,lo=0x...,hi=0x...[,from=0x...][,to=0x...],out=FILE
 *
 *  Counts every executed instruction whose address is in [lo, hi), the
 *  image's executable range, so a whole-system emulator's own code outside
 *  the image is not counted.  With `from`, the count starts when that
 *  address is first executed; with `to`, it stops and is written when that
 *  address is first executed, so a firmware run stopped by its debugger at
 *  the firmware return still writes it.  Otherwise it is written at exit.
 *  FILE receives one line: `instructions N`.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <glib.h>
#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

static uint64_t lo, hi, from, to;
static int have_from, have_to, started, written;
static uint64_t start_count;
static char *out;
static struct qemu_plugin_scoreboard *board;
static qemu_plugin_u64 counted;

static void write_count(uint64_t value)
{
    FILE *file;
    if (written)
        return;
    written = 1;
    file = fopen(out, "w");
    if (file == NULL)
        return;
    fprintf(file, "instructions %" PRIu64 "\n", value);
    fclose(file);
}

static void at_from(unsigned int vcpu, void *data)
{
    if (!started) {
        started = 1;
        start_count = qemu_plugin_u64_sum(counted);
    }
}

static void at_to(unsigned int vcpu, void *data)
{
    if (started)
        write_count(qemu_plugin_u64_sum(counted) - start_count);
}

static void translated(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    size_t count = qemu_plugin_tb_n_insns(tb);
    for (size_t index = 0; index < count; index++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, index);
        uint64_t address = qemu_plugin_insn_vaddr(insn);
        if (have_from && address == from)
            qemu_plugin_register_vcpu_insn_exec_cb(
                insn, at_from, QEMU_PLUGIN_CB_NO_REGS, NULL);
        if (address >= lo && address < hi)
            qemu_plugin_register_vcpu_insn_exec_inline_per_vcpu(
                insn, QEMU_PLUGIN_INLINE_ADD_U64, counted, 1);
        if (have_to && address == to)
            qemu_plugin_register_vcpu_insn_exec_cb(
                insn, at_to, QEMU_PLUGIN_CB_NO_REGS, NULL);
    }
}

static void at_exit(qemu_plugin_id_t id, void *data)
{
    if (!have_to)
        write_count(qemu_plugin_u64_sum(counted) - start_count);
}

static int number(const char *text, uint64_t *value)
{
    char *end;
    *value = strtoull(text, &end, 0);
    return *text != '\0' && *end == '\0';
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const qemu_info_t *info,
                                           int argc, char **argv)
{
    int have_lo = 0, have_hi = 0;
    for (int index = 0; index < argc; index++) {
        char *value = strchr(argv[index], '=');
        if (value == NULL)
            return -1;
        *value++ = '\0';
        if (strcmp(argv[index], "lo") == 0)
            have_lo = number(value, &lo);
        else if (strcmp(argv[index], "hi") == 0)
            have_hi = number(value, &hi);
        else if (strcmp(argv[index], "from") == 0)
            have_from = number(value, &from);
        else if (strcmp(argv[index], "to") == 0)
            have_to = number(value, &to);
        else if (strcmp(argv[index], "out") == 0)
            out = strdup(value);
        else
            return -1;
    }
    if (!have_lo || !have_hi || out == NULL || lo >= hi)
        return -1;
    started = !have_from;
    board = qemu_plugin_scoreboard_new(sizeof(uint64_t));
    counted = qemu_plugin_scoreboard_u64(board);
    qemu_plugin_register_vcpu_tb_trans_cb(id, translated);
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
