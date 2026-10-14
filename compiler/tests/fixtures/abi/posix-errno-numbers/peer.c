/*
 * Every errno platform/posix names, in its order, as this system's C
 * header defines it, or -1 where the header does not define it.  The
 * Landin program holds posix.number and posix.errno_of to these.
 */
#include <errno.h>
#include <stdint.h>

static const int32_t numbers[] = {
#ifdef EPERM
    EPERM,
#else
    -1,
#endif
#ifdef ENOENT
    ENOENT,
#else
    -1,
#endif
#ifdef ESRCH
    ESRCH,
#else
    -1,
#endif
#ifdef EINTR
    EINTR,
#else
    -1,
#endif
#ifdef EIO
    EIO,
#else
    -1,
#endif
#ifdef ENXIO
    ENXIO,
#else
    -1,
#endif
#ifdef E2BIG
    E2BIG,
#else
    -1,
#endif
#ifdef ENOEXEC
    ENOEXEC,
#else
    -1,
#endif
#ifdef EBADF
    EBADF,
#else
    -1,
#endif
#ifdef ECHILD
    ECHILD,
#else
    -1,
#endif
#ifdef EAGAIN
    EAGAIN,
#else
    -1,
#endif
#ifdef ENOMEM
    ENOMEM,
#else
    -1,
#endif
#ifdef EACCES
    EACCES,
#else
    -1,
#endif
#ifdef EFAULT
    EFAULT,
#else
    -1,
#endif
#ifdef ENOTBLK
    ENOTBLK,
#else
    -1,
#endif
#ifdef EBUSY
    EBUSY,
#else
    -1,
#endif
#ifdef EEXIST
    EEXIST,
#else
    -1,
#endif
#ifdef EXDEV
    EXDEV,
#else
    -1,
#endif
#ifdef ENODEV
    ENODEV,
#else
    -1,
#endif
#ifdef ENOTDIR
    ENOTDIR,
#else
    -1,
#endif
#ifdef EISDIR
    EISDIR,
#else
    -1,
#endif
#ifdef EINVAL
    EINVAL,
#else
    -1,
#endif
#ifdef ENFILE
    ENFILE,
#else
    -1,
#endif
#ifdef EMFILE
    EMFILE,
#else
    -1,
#endif
#ifdef ENOTTY
    ENOTTY,
#else
    -1,
#endif
#ifdef ETXTBSY
    ETXTBSY,
#else
    -1,
#endif
#ifdef EFBIG
    EFBIG,
#else
    -1,
#endif
#ifdef ENOSPC
    ENOSPC,
#else
    -1,
#endif
#ifdef ESPIPE
    ESPIPE,
#else
    -1,
#endif
#ifdef EROFS
    EROFS,
#else
    -1,
#endif
#ifdef EMLINK
    EMLINK,
#else
    -1,
#endif
#ifdef EPIPE
    EPIPE,
#else
    -1,
#endif
#ifdef EDOM
    EDOM,
#else
    -1,
#endif
#ifdef ERANGE
    ERANGE,
#else
    -1,
#endif
#ifdef EDEADLK
    EDEADLK,
#else
    -1,
#endif
#ifdef ENAMETOOLONG
    ENAMETOOLONG,
#else
    -1,
#endif
#ifdef ENOLCK
    ENOLCK,
#else
    -1,
#endif
#ifdef ENOSYS
    ENOSYS,
#else
    -1,
#endif
#ifdef ENOTEMPTY
    ENOTEMPTY,
#else
    -1,
#endif
#ifdef ELOOP
    ELOOP,
#else
    -1,
#endif
#ifdef ENOMSG
    ENOMSG,
#else
    -1,
#endif
#ifdef EIDRM
    EIDRM,
#else
    -1,
#endif
#ifdef ECHRNG
    ECHRNG,
#else
    -1,
#endif
#ifdef EL2NSYNC
    EL2NSYNC,
#else
    -1,
#endif
#ifdef EL3HLT
    EL3HLT,
#else
    -1,
#endif
#ifdef EL3RST
    EL3RST,
#else
    -1,
#endif
#ifdef ELNRNG
    ELNRNG,
#else
    -1,
#endif
#ifdef EUNATCH
    EUNATCH,
#else
    -1,
#endif
#ifdef ENOCSI
    ENOCSI,
#else
    -1,
#endif
#ifdef EL2HLT
    EL2HLT,
#else
    -1,
#endif
#ifdef EBADE
    EBADE,
#else
    -1,
#endif
#ifdef EBADR
    EBADR,
#else
    -1,
#endif
#ifdef EXFULL
    EXFULL,
#else
    -1,
#endif
#ifdef ENOANO
    ENOANO,
#else
    -1,
#endif
#ifdef EBADRQC
    EBADRQC,
#else
    -1,
#endif
#ifdef EBADSLT
    EBADSLT,
#else
    -1,
#endif
#ifdef EBFONT
    EBFONT,
#else
    -1,
#endif
#ifdef ENOSTR
    ENOSTR,
#else
    -1,
#endif
#ifdef ENODATA
    ENODATA,
#else
    -1,
#endif
#ifdef ETIME
    ETIME,
#else
    -1,
#endif
#ifdef ENOSR
    ENOSR,
#else
    -1,
#endif
#ifdef ENONET
    ENONET,
#else
    -1,
#endif
#ifdef ENOPKG
    ENOPKG,
#else
    -1,
#endif
#ifdef EREMOTE
    EREMOTE,
#else
    -1,
#endif
#ifdef ENOLINK
    ENOLINK,
#else
    -1,
#endif
#ifdef EADV
    EADV,
#else
    -1,
#endif
#ifdef ESRMNT
    ESRMNT,
#else
    -1,
#endif
#ifdef ECOMM
    ECOMM,
#else
    -1,
#endif
#ifdef EPROTO
    EPROTO,
#else
    -1,
#endif
#ifdef EMULTIHOP
    EMULTIHOP,
#else
    -1,
#endif
#ifdef EDOTDOT
    EDOTDOT,
#else
    -1,
#endif
#ifdef EBADMSG
    EBADMSG,
#else
    -1,
#endif
#ifdef EOVERFLOW
    EOVERFLOW,
#else
    -1,
#endif
#ifdef ENOTUNIQ
    ENOTUNIQ,
#else
    -1,
#endif
#ifdef EBADFD
    EBADFD,
#else
    -1,
#endif
#ifdef EREMCHG
    EREMCHG,
#else
    -1,
#endif
#ifdef ELIBACC
    ELIBACC,
#else
    -1,
#endif
#ifdef ELIBBAD
    ELIBBAD,
#else
    -1,
#endif
#ifdef ELIBSCN
    ELIBSCN,
#else
    -1,
#endif
#ifdef ELIBMAX
    ELIBMAX,
#else
    -1,
#endif
#ifdef ELIBEXEC
    ELIBEXEC,
#else
    -1,
#endif
#ifdef EILSEQ
    EILSEQ,
#else
    -1,
#endif
#ifdef ERESTART
    ERESTART,
#else
    -1,
#endif
#ifdef ESTRPIPE
    ESTRPIPE,
#else
    -1,
#endif
#ifdef EUSERS
    EUSERS,
#else
    -1,
#endif
#ifdef ENOTSOCK
    ENOTSOCK,
#else
    -1,
#endif
#ifdef EDESTADDRREQ
    EDESTADDRREQ,
#else
    -1,
#endif
#ifdef EMSGSIZE
    EMSGSIZE,
#else
    -1,
#endif
#ifdef EPROTOTYPE
    EPROTOTYPE,
#else
    -1,
#endif
#ifdef ENOPROTOOPT
    ENOPROTOOPT,
#else
    -1,
#endif
#ifdef EPROTONOSUPPORT
    EPROTONOSUPPORT,
#else
    -1,
#endif
#ifdef ESOCKTNOSUPPORT
    ESOCKTNOSUPPORT,
#else
    -1,
#endif
#ifdef EOPNOTSUPP
    EOPNOTSUPP,
#else
    -1,
#endif
#ifdef EPFNOSUPPORT
    EPFNOSUPPORT,
#else
    -1,
#endif
#ifdef EAFNOSUPPORT
    EAFNOSUPPORT,
#else
    -1,
#endif
#ifdef EADDRINUSE
    EADDRINUSE,
#else
    -1,
#endif
#ifdef EADDRNOTAVAIL
    EADDRNOTAVAIL,
#else
    -1,
#endif
#ifdef ENETDOWN
    ENETDOWN,
#else
    -1,
#endif
#ifdef ENETUNREACH
    ENETUNREACH,
#else
    -1,
#endif
#ifdef ENETRESET
    ENETRESET,
#else
    -1,
#endif
#ifdef ECONNABORTED
    ECONNABORTED,
#else
    -1,
#endif
#ifdef ECONNRESET
    ECONNRESET,
#else
    -1,
#endif
#ifdef ENOBUFS
    ENOBUFS,
#else
    -1,
#endif
#ifdef EISCONN
    EISCONN,
#else
    -1,
#endif
#ifdef ENOTCONN
    ENOTCONN,
#else
    -1,
#endif
#ifdef ESHUTDOWN
    ESHUTDOWN,
#else
    -1,
#endif
#ifdef ETOOMANYREFS
    ETOOMANYREFS,
#else
    -1,
#endif
#ifdef ETIMEDOUT
    ETIMEDOUT,
#else
    -1,
#endif
#ifdef ECONNREFUSED
    ECONNREFUSED,
#else
    -1,
#endif
#ifdef EHOSTDOWN
    EHOSTDOWN,
#else
    -1,
#endif
#ifdef EHOSTUNREACH
    EHOSTUNREACH,
#else
    -1,
#endif
#ifdef EALREADY
    EALREADY,
#else
    -1,
#endif
#ifdef EINPROGRESS
    EINPROGRESS,
#else
    -1,
#endif
#ifdef ESTALE
    ESTALE,
#else
    -1,
#endif
#ifdef EUCLEAN
    EUCLEAN,
#else
    -1,
#endif
#ifdef ENOTNAM
    ENOTNAM,
#else
    -1,
#endif
#ifdef ENAVAIL
    ENAVAIL,
#else
    -1,
#endif
#ifdef EISNAM
    EISNAM,
#else
    -1,
#endif
#ifdef EREMOTEIO
    EREMOTEIO,
#else
    -1,
#endif
#ifdef EDQUOT
    EDQUOT,
#else
    -1,
#endif
#ifdef ENOMEDIUM
    ENOMEDIUM,
#else
    -1,
#endif
#ifdef EMEDIUMTYPE
    EMEDIUMTYPE,
#else
    -1,
#endif
#ifdef ECANCELED
    ECANCELED,
#else
    -1,
#endif
#ifdef ENOKEY
    ENOKEY,
#else
    -1,
#endif
#ifdef EKEYEXPIRED
    EKEYEXPIRED,
#else
    -1,
#endif
#ifdef EKEYREVOKED
    EKEYREVOKED,
#else
    -1,
#endif
#ifdef EKEYREJECTED
    EKEYREJECTED,
#else
    -1,
#endif
#ifdef EOWNERDEAD
    EOWNERDEAD,
#else
    -1,
#endif
#ifdef ENOTRECOVERABLE
    ENOTRECOVERABLE,
#else
    -1,
#endif
#ifdef ERFKILL
    ERFKILL,
#else
    -1,
#endif
#ifdef EHWPOISON
    EHWPOISON,
#else
    -1,
#endif
#ifdef EAUTH
    EAUTH,
#else
    -1,
#endif
#ifdef EBADARCH
    EBADARCH,
#else
    -1,
#endif
#ifdef EBADEXEC
    EBADEXEC,
#else
    -1,
#endif
#ifdef EBADMACHO
    EBADMACHO,
#else
    -1,
#endif
#ifdef EBADRPC
    EBADRPC,
#else
    -1,
#endif
#ifdef ECAPMODE
    ECAPMODE,
#else
    -1,
#endif
#ifdef EDEVERR
    EDEVERR,
#else
    -1,
#endif
#ifdef EDOOFUS
    EDOOFUS,
#else
    -1,
#endif
#ifdef EFTYPE
    EFTYPE,
#else
    -1,
#endif
#ifdef EINTEGRITY
    EINTEGRITY,
#else
    -1,
#endif
#ifdef ENEEDAUTH
    ENEEDAUTH,
#else
    -1,
#endif
#ifdef ENOATTR
    ENOATTR,
#else
    -1,
#endif
#ifdef ENOPOLICY
    ENOPOLICY,
#else
    -1,
#endif
#ifdef ENOTCAPABLE
    ENOTCAPABLE,
#else
    -1,
#endif
#ifdef ENOTSUP
    ENOTSUP,
#else
    -1,
#endif
#ifdef EPROCLIM
    EPROCLIM,
#else
    -1,
#endif
#ifdef EPROCUNAVAIL
    EPROCUNAVAIL,
#else
    -1,
#endif
#ifdef EPROGMISMATCH
    EPROGMISMATCH,
#else
    -1,
#endif
#ifdef EPROGUNAVAIL
    EPROGUNAVAIL,
#else
    -1,
#endif
#ifdef EPWROFF
    EPWROFF,
#else
    -1,
#endif
#ifdef EQFULL
    EQFULL,
#else
    -1,
#endif
#ifdef ERPCMISMATCH
    ERPCMISMATCH,
#else
    -1,
#endif
#ifdef ESHLIBVERS
    ESHLIBVERS,
#else
    -1,
#endif
};

int32_t posix_errno_count(void)
{
    return (int32_t)(sizeof numbers / sizeof numbers[0]);
}

int32_t posix_errno_number(int32_t index)
{
    return numbers[index];
}
