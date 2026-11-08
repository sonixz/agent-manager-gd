# Agent Manager GD sandbox image: tmux, git, SSH server (port 2222, keys only), Node, Claude Code, Codex.
# Built remotely by Fly (flyctl deploy --build-only --push) into the organisation's private registry.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm-256color
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends tmux git openssh-server openssh-client curl ca-certificates nodejs npm python3 \
 && npm install -g --silent @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /root/.ssh /work && chmod 700 /root/.ssh \
 && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/; s/^#\?AllowTcpForwarding.*/AllowTcpForwarding yes/; s/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
COPY start.sh /usr/local/bin/agmgd-start
RUN chmod +x /usr/local/bin/agmgd-start
WORKDIR /work
CMD ["/usr/local/bin/agmgd-start"]
