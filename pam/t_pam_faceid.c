/*
 * t_pam_faceid — dlopen the pam_faceid module and call pam_sm_authenticate
 * the same way Linux-PAM would.
 *
 * Build:
 *     cc -O2 -Wall -o t_pam_faceid t_pam_faceid.c -ldl -lpam
 *
 * Usage:
 *     ./t_pam_faceid /path/to/pam_faceid.so
 */
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <dlfcn.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef int (*pam_sm_fn)(pam_handle_t *, int, int, const char **);

int main(int argc, char **argv)
{
    const char *modpath = "pam_faceid.so";
    if (argc > 1)
        modpath = argv[1];

    void *h = dlopen(modpath, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    pam_sm_fn auth = (pam_sm_fn)dlsym(h, "pam_sm_authenticate");
    if (!auth) {
        fprintf(stderr, "no pam_sm_authenticate: %s\n", dlerror());
        return 1;
    }

    struct pam_conv conv = {NULL, NULL}; /* never used by our module */
    pam_handle_t *pamh = NULL;
    int ret = pam_start("doas", getenv("USER") ? getenv("USER") : "nbz", &conv, &pamh);
    if (ret != PAM_SUCCESS) {
        fprintf(stderr, "pam_start: %s\n", pam_strerror(pamh, ret));
        return 1;
    }

    ret = auth(pamh, 0, 0, NULL);
    printf("pam_sm_authenticate = %d (%s)\n", ret, pam_strerror(pamh, ret));

    pam_end(pamh, ret);
    dlclose(h);
    return ret == PAM_SUCCESS ? 0 : 1;
}