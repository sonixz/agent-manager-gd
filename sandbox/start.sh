#!/bin/sh
# The sandbox's public key comes from the machine's environment (AGMGD_AUTHORIZED_KEY, a public key: not a secret).
if [ -n "$AGMGD_AUTHORIZED_KEY" ]; then echo "$AGMGD_AUTHORIZED_KEY" > /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys; fi
ssh-keygen -A >/dev/null 2>&1
/usr/sbin/sshd -p 2222
# Loop 48: the door. Fly's 443 reaches 8443; it passes on to the port bound to the public URL (none: nothing passes).
python3 /usr/local/bin/agmgd-door >>/var/log/agmgd_door.log 2>&1 &
# Loop 43 (Online machines): the service starts again by itself after a restart. The agent writes /data/start.sh
# (on the volume, kept); it runs here at boot with the secrets given to the machine, its output in /data/start.log.
if [ -x /data/start.sh ]; then
  ( cd /data && { [ -f /data/.agmgd/secrets ] && . /data/.agmgd/secrets; true; } && echo "== boot $(date -u +%FT%TZ)" && exec /data/start.sh ) >> /data/start.log 2>&1 &
fi
exec sleep infinity
