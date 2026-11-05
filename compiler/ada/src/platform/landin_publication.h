#ifndef LANDIN_PUBLICATION_H
#define LANDIN_PUBLICATION_H
#include <stddef.h>
#include <stdint.h>
/* Callback is only installed by the deterministic native harness. */
typedef void (*landin_publication_hook)(const char *event, const char *path);
void landin_publication_set_hook(landin_publication_hook hook);
int landin_publication_open(const char *, int, const char *, int *, char *, size_t,
                            char *, size_t);
int landin_publication_step(int, int, const char *const *, size_t,
                            const uint64_t *, size_t, char *, size_t);
int landin_read_snapshot(const char *, char **, size_t *, uint64_t *, uint64_t *);
void landin_snapshot_free(char *);
int landin_publication_stage_directory(const char *);
int landin_publication_rebase_argument(const char *, int, char *, size_t);
int landin_publication_stage_write(const char *, const char *, size_t);
#endif
