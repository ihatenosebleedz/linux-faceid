CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -fPIC
PAM_DEST ?= /usr/lib/security

all: pam_faceid.so

pam_faceid.so: pam_faceid.c
	$(CC) $(CFLAGS) -shared -o $@ $< -lpam

install: pam_faceid.so
	install -d $(PAM_DEST)
	install -m 755 pam_faceid.so $(PAM_DEST)/pam_faceid.so

clean:
	rm -f pam_faceid.so t_pam_faceid

test: t_pam_faceid.c
	$(CC) $(CFLAGS) -o t_pam_faceid t_pam_faceid.c -lpam
	./t_pam_faceid

.PHONY: all install clean test
