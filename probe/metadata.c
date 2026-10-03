#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/acl.h>
#include <sys/xattr.h>
#include <unistd.h>
#include "../compiler/ada/src/platform/landin_format_replace.c"
int main(int argc, char **argv) {
    (void)argc;
    struct stat s;
    int fd = open(argv[1], O_RDONLY);
    fstat(fd, &s);
    printf("uid=%u gid=%u file_uid=%u file_gid=%u mode=%o\n", getuid(), getgid(), s.st_uid, s.st_gid, s.st_mode & 07777);
    errno=0; ssize_t n=flistxattr(fd,NULL,0,0); int e=errno;
    printf("flistxattr=%ld errno=%d\n",(long)n,e);
    errno=0; acl_t a=acl_get_fd_np(fd,ACL_TYPE_EXTENDED); e=errno;
    printf("acl=%p errno=%d\n",(void*)a,e);
    if(a) { acl_entry_t entry; errno=0; int r=acl_get_entry(a,ACL_FIRST_ENTRY,&entry); e=errno; printf("acl_get_entry=%d errno=%d\n",r,e); acl_free(a); }
    close(fd);
    errno=0; int r=landin_replace_existing_file(argv[1],"x: u32 = 0\n",11);e=errno;
    printf("replace=%d errno=%d\n",r,e);
    fd=open(argv[1],O_RDWR);fstat(fd,&s);
    errno=0;r=fchown(fd,s.st_uid,s.st_gid);e=errno;printf("same_owner_chown=%d errno=%d\n",r,e);
    errno=0;r=fchmod(fd,02755);e=errno;fstat(fd,&s);printf("setgid_chmod=%d errno=%d actual=%o\n",r,e,s.st_mode&07777);
    errno=0;r=fchown(fd,getuid(),getgid());e=errno;printf("caller_group_chown=%d errno=%d\n",r,e);
    errno=0;r=fchmod(fd,02755);e=errno;fstat(fd,&s);printf("caller_group_chmod=%d errno=%d actual=%o\n",r,e,s.st_mode&07777);
    close(fd);return 0;
}
