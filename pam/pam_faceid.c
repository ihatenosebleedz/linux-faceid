/*
 * pam_faceid — PAM module that authenticates against the linux-faceid
 * daemon instead of the password.
 *
 * The module is meant to sit at the TOP of a PAM stack as `sufficient`:
 *
 *     auth sufficient pam_faceid.so
 *     auth include system-auth
 *
 * When the daemon reports a matching face, pam_sm_authenticate returns
 * PAM_SUCCESS and the stack short-circuits (no password needed). Anything
 * else (daemon down, no profile, no match, timeout) returns PAM_IGNORE so
 * the stack falls through to the normal password prompt.
 *
 * Protocol: connects to $XDG_RUNTIME_DIR/linux-faceid.sock and sends
 *     {"command":"auth"}
 * then reads line-delimited JSON until it sees
 *     {"event":"auth_result","data":{"ok":true|false,...}}
 *
 * Build (Void, after doas xbps-install pam-devel):
 *     cc -O2 -fPIC -shared -o pam_faceid.so pam_faceid.c -lpam
 *     doas install -m 755 pam_faceid.so /usr/lib/security/pam_faceid.so
 */

#include <security/pam_appl.h>
#include <security/pam_ext.h>
#include <security/pam_modules.h>

#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syslog.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

/* How long to wait for the daemon to answer an auth request. The daemon
 * itself gives up after AUTH_TIMEOUT (20s); 30s here is generous. */
#define AUTH_ALLOWED_WAIT_MS 30000

#define REPLY_BUF_SIZE 4096

static const char *faceid_socket_path(void)
{
    static char path[128];
    snprintf(path, sizeof(path),
             "/run/user/%u/linux-faceid.sock", (unsigned)getuid());
    return path;
}

static int faceid_matches(pam_handle_t *pamh)
{
    const char *socket_path = faceid_socket_path();
    struct sockaddr_un addr;
    int fd = -1;
    struct pollfd pfd;
    char buf[REPLY_BUF_SIZE];
    size_t used = 0;
    unsigned long long waited = 0;
    int ok = 0;

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return 0;

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        pam_syslog(pamh, LOG_DEBUG, "faceid: connect %s: %s",
                   socket_path, strerror(errno));
        close(fd);
        return 0;
    }

    const char *request = "{\"command\":\"auth\"}\n";
    if (send(fd, request, strlen(request), 0) != (ssize_t)strlen(request)) {
        close(fd);
        return 0;
    }

    memset(buf, 0, sizeof(buf));

    while (waited < AUTH_ALLOWED_WAIT_MS) {
        pfd.fd = fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, 500);
        if (rc < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (rc == 0) {
            waited += 500;
            continue;
        }
        if (!(pfd.revents & POLLIN))
            break;

        ssize_t n = recv(fd, buf + used, sizeof(buf) - 1 - used, 0);
        if (n <= 0)
            break;
        used += (size_t)n;
        buf[used] = '\0';

        /* Scan every complete line for the decisive auth_result event. */
        char *line = buf;
        char *nl;
        while ((nl = strchr(line, '\n')) != NULL) {
            *nl = '\0';
            if (strstr(line, "\"event\":\"auth_result\"") ||
                strstr(line, "\"event\": \"auth_result\"")) {
                ok = strstr(line, "\"ok\":true") != NULL;
                close(fd);
                pam_syslog(pamh, LOG_INFO, "faceid: auth %s", ok ? "ok" : "denied");
                return ok;
            }
            line = nl + 1;
        }

        /* Keep any partial trailing line by shifting it to the front. */
        if (line > buf) {
            memmove(buf, line, strlen(line) + 1);
            used = strlen(buf);
        }
    }

    close(fd);
    pam_syslog(pamh, LOG_INFO, "faceid: no auth_result (timeout)");
    return 0;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                   int argc, const char **argv)
{
    (void)flags;
    (void)argc;
    (void)argv;

    /* If the daemon is not running there is no socket to hand the check to;
     * fall through to the password like a "try_first_pass" fallback. */
    if (access(faceid_socket_path(), F_OK) != 0)
        return PAM_IGNORE;

    if (faceid_matches(pamh))
        return PAM_SUCCESS;

    /* Not a match / no answer: let the rest of the stack (password) decide. */
    return PAM_IGNORE;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                              int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags,
                                int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}