#ifndef LANDIN_PUBLICATION_H
#define LANDIN_PUBLICATION_H
#include <stddef.h>
#include <stdint.h>
/* Test-only callback: configure while no adapter call is active. A callback
   must not reenter the registry whose operation invoked it. */
typedef void (*landin_publication_hook)(const char *event, const char *path);
#define LANDIN_PUBLICATION_DELETE_ONLY 1
#define LANDIN_PUBLICATION_REQUIRE_ABSENT 2
/* The artifact is a directory tree. Only then is an existing directory at
   the destination read, to be replaced; without it a directory there
   refuses the preparation at once. */
#define LANDIN_PUBLICATION_DIRECTORY 4
void landin_publication_set_hook(landin_publication_hook hook);
void landin_publication_notify(const char *, const char *);
/* The second argument combines the DELETE_ONLY, REQUIRE_ABSENT and
   DIRECTORY flags. */
int landin_publication_open(const char *, int, const char *, int *, char *, size_t,
                            char *, size_t);
/* Successful Finish invalidates the handle. Arena components beginning with
   .refine-publication- are reserved: unregistered stage authority refuses,
   including alternate empty/dot separators, without pathname fallback. */
int landin_publication_step(int, int, const char *const *, size_t,
                            const uint64_t *, size_t, char *, size_t);
int landin_read_snapshot(const char *, char **, size_t *, uint64_t *, uint64_t *);
void landin_snapshot_free(char *);
/* Returns 1 for a verified observed pathname, 0 for a qualified fallback. */
int landin_publication_describe_entry(int, const char *, const char *, char *, size_t);
int landin_publication_stage_directory(const char *);
int landin_publication_rebase_argument(const char *, int, char *, size_t);
int landin_publication_stage_write(const char *, const char *, size_t);
int landin_publication_stage_write_reason(const char *, const char *, size_t,
                                           char *, size_t);
/* Exclusive creation: an occupied staged entry, even a directory, refuses.
   0 success, -1 claimed private path refused, -2 outside the registry.
   A claimed path must never fall back to pathname-based creation. */
int landin_publication_stage_mkdir(const char *);
#endif
