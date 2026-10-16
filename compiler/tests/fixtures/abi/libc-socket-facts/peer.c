/*
 * Holds the facts platform/libc, platform/linux and platform/posix keep
 * for sockets and SIGPIPE to this system's own C headers, and the address
 * records platform/posix lays out to C's own.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>

extern int64_t l_number(int32_t index);
extern int64_t l_offset(int32_t index);
extern uint32_t l_encoded(int32_t index, uint8_t *into);
extern int64_t l_decoded(const uint8_t *from, uint32_t length);
#if defined(__linux__)
extern bool l_linux_agrees(void);
#endif
#if defined(__linux__) || defined(__FreeBSD__)
extern int32_t l_cloexec_flag(void);
extern int32_t l_no_signal(void);
#endif
#if defined(__APPLE__) || defined(__FreeBSD__)
extern int32_t l_no_sigpipe(void);
extern int16_t l_setsigdef(void);
#endif

static const int64_t expected[] = {
    AF_UNIX, AF_INET, AF_INET6, SOCK_STREAM, SOCK_DGRAM, SOL_SOCKET,
    SO_REUSEADDR, SO_ERROR, SO_RCVTIMEO, SO_SNDTIMEO, IPPROTO_TCP,
    IPPROTO_IPV6, TCP_NODELAY, IPV6_V6ONLY, SHUT_RD, SHUT_WR, SHUT_RDWR,
    SIGPIPE, (int64_t)(uintptr_t)SIG_DFL, (int64_t)(uintptr_t)SIG_IGN,
    F_GETFD, sizeof(struct sockaddr_storage), sizeof(struct sockaddr_in),
    sizeof(struct sockaddr_in6), sizeof(((struct sockaddr_un *)0)->sun_path),
    sizeof(struct timeval), sizeof(struct sigaction), sizeof(sigset_t),
};

int main(void)
{
    for (int32_t i = 0; i < (int32_t)(sizeof expected / sizeof expected[0]);
         i++)
        if (l_number(i) != expected[i])
            return 10 + i;
    if (l_offset(0) != (int64_t)offsetof(struct timeval, tv_usec)
        || l_offset(1) != (int64_t)offsetof(struct sigaction, sa_flags)
        || l_offset(2) != (int64_t)offsetof(struct sigaction, sa_mask))
        return 2;
#if defined(__linux__)
    if (!l_linux_agrees())
        return 3;
#endif
#if defined(__linux__) || defined(__FreeBSD__)
    if (l_cloexec_flag() != SOCK_CLOEXEC || l_no_signal() != MSG_NOSIGNAL)
        return 4;
#endif
#if defined(__APPLE__) || defined(__FreeBSD__)
    if (l_no_sigpipe() != SO_NOSIGPIPE || l_setsigdef() != POSIX_SPAWN_SETSIGDEF)
        return 5;
#endif

    /* What platform/posix lays out is what C lays out. */
    uint8_t got[128];
    struct sockaddr_in four;
    memset(&four, 0, sizeof four);
#if defined(__APPLE__) || defined(__FreeBSD__)
    four.sin_len = sizeof four;
#endif
    four.sin_family = AF_INET;
    four.sin_port = htons(8080);
    if (inet_pton(AF_INET, "192.0.2.1", &four.sin_addr) != 1)
        return 6;
    memset(got, 0xAA, sizeof got);
    if (l_encoded(0, got) != sizeof four || memcmp(got, &four, sizeof four))
        return 7;
    struct sockaddr_in6 six;
    memset(&six, 0, sizeof six);
#if defined(__APPLE__) || defined(__FreeBSD__)
    six.sin6_len = sizeof six;
#endif
    six.sin6_family = AF_INET6;
    six.sin6_port = htons(443);
    if (inet_pton(AF_INET6, "2001:db8::1", &six.sin6_addr) != 1)
        return 8;
    memset(got, 0xAA, sizeof got);
    if (l_encoded(1, got) != sizeof six || memcmp(got, &six, sizeof six))
        return 9;
    struct sockaddr_un local;
    memset(&local, 0, sizeof local);
    uint32_t length = l_encoded(2, got);
    memcpy(&local, got, length);
    if (local.sun_family != AF_UNIX || strcmp(local.sun_path, "/tmp/landin.sock")
        || length != offsetof(struct sockaddr_un, sun_path) + 17)
        return 40;

    /* And what C lays out, platform/posix reads. */
    struct sockaddr_in6 back;
    memset(&back, 0, sizeof back);
#if defined(__APPLE__) || defined(__FreeBSD__)
    back.sin6_len = sizeof back;
#endif
    back.sin6_family = AF_INET6;
    back.sin6_port = htons(65534);
    if (inet_pton(AF_INET6, "fe80::77", &back.sin6_addr) != 1)
        return 41;
    back.sin6_scope_id = 3;
    if (l_decoded((const uint8_t *)&back, sizeof back)
        != ((int64_t)1 << 32 | (int64_t)65534 << 8 | 0x77))
        return 42 + 1;
    struct sockaddr_in front;
    memset(&front, 0, sizeof front);
#if defined(__APPLE__) || defined(__FreeBSD__)
    front.sin_len = sizeof front;
#endif
    front.sin_family = AF_INET;
    front.sin_port = htons(1);
    if (inet_pton(AF_INET, "10.20.30.40", &front.sin_addr) != 1)
        return 44;
    if (l_decoded((const uint8_t *)&front, sizeof front)
        != ((int64_t)1 << 8 | 40))
        return 45;
    if (l_decoded(got, length) != -1)
        return 46;
    return 42;
}
