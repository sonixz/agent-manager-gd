#!/bin/sh
# The sandbox's public key comes from the machine's environment (AGMGD_AUTHORIZED_KEY, a public key: not a secret).
if [ -n "$AGMGD_AUTHORIZED_KEY" ]; then echo "$AGMGD_AUTHORIZED_KEY" > /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; fi
ssh-keygen -A >/dev/null 2>&1
/usr/sbin/sshd -p 2222
exec sleep infinity
