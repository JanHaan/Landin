/*  The instructions a program's own code executed, for docs/measurement.md's
 *  `instructions` class: a QEMU TCG plugin, built by scripts/measure_count.py
 *  for the plugin API version the running QEMU accepts.
 *
 *      -plugin count.so,lo=0x...,hi=0x...[,from=0x...][,to=0x...],out=FILE
 *
 *  Counts every executed instruction whose address is in [lo, hi), the
 *  image's executable range, so a whole-system emulator's own code outside
 *  the image is not counted.  With `from`, the count starts when that
 *  address is first about to execute; with `to`, it stops there, so the
 *  instruction at `to` is not counted.  FILE receives one line,
 *  `instructions N`, when QEMU exits, including when a debugger stopped at
 *  `to` kills it: a breakpoint there is taken before the instruction's own
 *  callback, so the count is the same either way.  `reached 0` follows it
 *  when `to` was given and its instruction was never about to execute.
 *
 *  It declares the dozen calls it uses rather than including QEMU's
 *  <qemu-plugin.h>: the header needs glib's, the Cortex-M lanes' Debian
 *  QEMU ships none, and the two API versions in use differ only in the
 *  callbacks below.  COUNT_API is the version measure_count.py found the
 *  running QEMU to accept: 2 to 6 share one form, and 7 passes user data
 *  to every callback.  Its declarations are the headers' own, compared
 *  by measure_count.py's `check-header` where a QEMU installs its header.
 */
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef COUNT_API
#error "COUNT_API, the QEMU plugin API version, is set by measure_count.py"
#endif

#ifdef COUNT_CHECK_HEADER
/*  The header's types, against which every declaration below must agree. */
#include <qemu-plugin.h>
#else
#define QEMU_PLUGIN_EXPORT __attribute__((visibility("default")))
typedef struct qemu_info_t qemu_info_t;
struct qemu_plugin_tb;
struct qemu_plugin_insn;
struct qemu_plugin_scoreboard;
typedef struct {
    struct qemu_plugin_scoreboard *score;
    size_t offset;
} qemu_plugin_u64;
enum qemu_plugin_cb_flags { QEMU_PLUGIN_CB_NO_REGS };
enum qemu_plugin_op { QEMU_PLUGIN_INLINE_ADD_U64 };
#define qemu_plugin_scoreboard_u64(score) ((qemu_plugin_u64){score, 0})
#endif

typedef uint64_t qemu_plugin_id_t;
typedef void (*qemu_plugin_vcpu_udata_cb_t)(unsigned int vcpu_index,
                                            void *userdata);
#if COUNT_API >= 7
typedef void (*qemu_plugin_udata_cb_t)(void *userdata);
typedef void (*qemu_plugin_vcpu_tb_trans_cb_t)(struct qemu_plugin_tb *tb,
                                               void *userdata);
void qemu_plugin_register_vcpu_tb_trans_cb(qemu_plugin_id_t id,
                                           qemu_plugin_vcpu_tb_trans_cb_t cb,
                                           void *userdata);
#else
typedef void (*qemu_plugin_udata_cb_t)(qemu_plugin_id_t id, void *userdata);
typedef void (*qemu_plugin_vcpu_tb_trans_cb_t)(qemu_plugin_id_t id,
                                               struct qemu_plugin_tb *tb);
void qemu_plugin_register_vcpu_tb_trans_cb(qemu_plugin_id_t id,
                                           qemu_plugin_vcpu_tb_trans_cb_t cb);
#endif
void qemu_plugin_register_vcpu_insn_exec_cb(struct qemu_plugin_insn *insn,
                                            qemu_plugin_vcpu_udata_cb_t cb,
                                            enum qemu_plugin_cb_flags flags,
                                            void *userdata);
void qemu_plugin_register_vcpu_insn_exec_inline_per_vcpu(
    struct qemu_plugin_insn *insn, enum qemu_plugin_op op,
    qemu_plugin_u64 entry, uint64_t imm);
void qemu_plugin_register_atexit_cb(qemu_plugin_id_t id,
                                    qemu_plugin_udata_cb_t cb, void *userdata);
size_t qemu_plugin_tb_n_insns(const struct qemu_plugin_tb *tb);
struct qemu_plugin_insn *qemu_plugin_tb_get_insn(const struct qemu_plugin_tb *tb,
                                                 size_t idx);
uint64_t qemu_plugin_insn_vaddr(const struct qemu_plugin_insn *insn);
struct qemu_plugin_scoreboard *qemu_plugin_scoreboard_new(size_t element_size);
uint64_t qemu_plugin_u64_sum(qemu_plugin_u64 entry);
int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info,
                        int argc, char **argv);

QEMU_PLUGIN_EXPORT int qemu_plugin_version = COUNT_API;

static uint64_t lo, hi, from, to;
static int have_from, have_to, started, stopped;
static uint64_t start_count, stop_count;
static char *out;
static qemu_plugin_u64 counted;

static void at_from(unsigned int vcpu, void *data)
{
    if (!started) {
        started = 1;
        start_count = qemu_plugin_u64_sum(counted);
    }
}

static void at_to(unsigned int vcpu, void *data)
{
    if (!stopped) {
        stopped = 1;
        stop_count = qemu_plugin_u64_sum(counted);
    }
}

static void instrument(struct qemu_plugin_tb *tb)
{
    size_t count = qemu_plugin_tb_n_insns(tb);
    for (size_t index = 0; index < count; index++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, index);
        uint64_t address = qemu_plugin_insn_vaddr(insn);
        /*  Both callbacks are registered before the count, and run before
         *  it, so `from`'s own instruction is counted and `to`'s is not. */
        if (have_from && address == from)
            qemu_plugin_register_vcpu_insn_exec_cb(
                insn, at_from, QEMU_PLUGIN_CB_NO_REGS, NULL);
        if (have_to && address == to)
            qemu_plugin_register_vcpu_insn_exec_cb(
                insn, at_to, QEMU_PLUGIN_CB_NO_REGS, NULL);
        if (address >= lo && address < hi)
            qemu_plugin_register_vcpu_insn_exec_inline_per_vcpu(
                insn, QEMU_PLUGIN_INLINE_ADD_U64, counted, 1);
    }
}

static void finish(void)
{
    uint64_t end = stopped ? stop_count : qemu_plugin_u64_sum(counted);
    FILE *file = fopen(out, "w");
    if (file == NULL)
        return;
    fprintf(file, "instructions %" PRIu64 "\n",
            started ? end - start_count : 0);
    if (!started)
        fprintf(file, "started 0\n");
    if (have_to && !stopped)
        fprintf(file, "reached 0\n");
    fclose(file);
}

#if COUNT_API >= 7
static void translated(struct qemu_plugin_tb *tb, void *data)
{
    instrument(tb);
}

static void at_exit(void *data)
{
    finish();
}
#else
static void translated(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    instrument(tb);
}

static void at_exit(qemu_plugin_id_t id, void *data)
{
    finish();
}
#endif

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
    counted = qemu_plugin_scoreboard_u64(
        qemu_plugin_scoreboard_new(sizeof(uint64_t)));
#if COUNT_API >= 7
    qemu_plugin_register_vcpu_tb_trans_cb(id, translated, NULL);
#else
    qemu_plugin_register_vcpu_tb_trans_cb(id, translated);
#endif
    qemu_plugin_register_atexit_cb(id, at_exit, NULL);
    return 0;
}
