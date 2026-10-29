/*
 * Holds the facts platform/linux, platform/kqueue and platform/libc keep
 * for the event interfaces to this system's own C headers, and their
 * records to C's own, both ways.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#if defined(__linux__)
#include <sys/epoll.h>
#include <sys/signalfd.h>
#else
#include <sys/event.h>
#endif

extern int64_t l_number(int32_t index);

#if defined(__linux__)
extern bool l_epoll_read(const struct epoll_event *record);
extern void l_epoll_write(struct epoll_event *into);
extern bool l_signalfd_read(const struct signalfd_siginfo *record);
extern uint64_t l_signal_bit(void);

static const int64_t expected[] = {
    sizeof(struct epoll_event), sizeof(struct signalfd_siginfo),
    EPOLL_CLOEXEC, EPOLL_CTL_ADD, EPOLL_CTL_DEL, EPOLL_CTL_MOD,
    (uint32_t)EPOLLIN, (uint32_t)EPOLLPRI, (uint32_t)EPOLLOUT,
    (uint32_t)EPOLLERR, (uint32_t)EPOLLHUP, (uint32_t)EPOLLRDHUP,
    (uint32_t)EPOLLONESHOT, (uint32_t)EPOLLET, SFD_CLOEXEC, SFD_NONBLOCK,
    SIG_BLOCK, SIG_UNBLOCK, SIG_SETMASK, SIGHUP, SIGINT, SIGUSR1, SIGUSR2,
    SIGTERM, O_NONBLOCK, SOCK_NONBLOCK, F_GETFL, F_SETFL,
    SIG_BLOCK, SIG_SETMASK, SIGUSR1, O_NONBLOCK, SOCK_NONBLOCK,
};
#else
extern bool l_kevent_read(const struct kevent *record);
extern void l_kevent_write(struct kevent *into);

static const int64_t expected[] = {
    sizeof(struct kevent), EVFILT_READ, EVFILT_WRITE, EVFILT_PROC,
    EVFILT_SIGNAL, EVFILT_TIMER, EV_ADD, EV_DELETE, EV_ENABLE, EV_DISABLE,
    EV_ONESHOT, EV_CLEAR, EV_EOF, EV_ERROR, (uint32_t)NOTE_EXIT,
    NOTE_SECONDS, NOTE_USECONDS, NOTE_NSECONDS, SIG_BLOCK, SIG_UNBLOCK,
    SIG_SETMASK, SIGHUP, SIGINT, SIGUSR1, SIGUSR2, SIGTERM, O_NONBLOCK,
    F_GETFL,
#if defined(__FreeBSD__)
    NOTE_MSECONDS, SOCK_NONBLOCK,
#endif
};
#endif

int main(void)
{
    int32_t count = (int32_t)(sizeof expected / sizeof expected[0]);
    for (int32_t i = 0; i < count; i++)
        if (l_number(i) != expected[i])
            return 10 + i;
    if (l_number(count) != -1)
        return 2;

#if defined(__linux__)
    struct epoll_event events[2];
    memset(events, 0, sizeof events);
    events[1].events = EPOLLIN | EPOLLET;
    events[1].data.u64 = 0x0102030405060708u;
    if (!l_epoll_read(&events[1]))
        return 3;
    memset(events, 0, sizeof events);
    l_epoll_write(&events[1]);
    if (events[1].events != (EPOLLOUT | EPOLLONESHOT)
        || events[1].data.u64 != 0x1112131415161718u
        || events[0].events != 0 || events[0].data.u64 != 0)
        return 4;

    struct signalfd_siginfo info;
    memset(&info, 0, sizeof info);
    info.ssi_signo = 10;
    info.ssi_code = -6;
    info.ssi_pid = 1234;
    info.ssi_uid = 1000;
    info.ssi_status = 3;
    info.ssi_ptr = 0x55;
    info.ssi_addr_lsb = 7;
    info.ssi_syscall = 77;
    info.ssi_call_addr = 0x99;
    info.ssi_arch = 0xc000003eu;
    if (!l_signalfd_read(&info))
        return 5;

    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGUSR1);
    uint64_t word;
    memcpy(&word, &mask, sizeof word);
    if (l_signal_bit() != word)
        return 6;
#else
    struct kevent records[2];
    memset(records, 0, sizeof records);
    EV_SET(&records[1], 7, EVFILT_SIGNAL, EV_ADD | EV_CLEAR, NOTE_EXIT, -5,
           (void *)0x1234);
    if (!l_kevent_read(&records[1]))
        return 3;
    memset(records, 0xff, sizeof records);
    l_kevent_write(&records[1]);
    struct kevent made;
    memset(&made, 0, sizeof made);
    EV_SET(&made, 3, EVFILT_TIMER, EV_ADD | EV_ONESHOT, NOTE_SECONDS, 2, 0);
    if (memcmp(&records[1], &made, sizeof made) != 0)
        return 4;
#endif
    return 42;
}
