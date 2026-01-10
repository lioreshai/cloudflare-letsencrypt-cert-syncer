FROM alpine:3.19

# Mock pfSense SSH server for testing cert-push script
# Responds to pfSense-style PHP commands and stores certificate state

RUN apk add --no-cache openssh-server openssl bash

# Create root user for pfSense-style access
RUN mkdir -p /root/.ssh && \
    chmod 700 /root/.ssh

# SSH configuration
RUN ssh-keygen -A && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    echo "AllowUsers root" >> /etc/ssh/sshd_config

# Create state directory for certificate tracking
RUN mkdir -p /state /tmp && \
    chmod 777 /state /tmp

# Install pfSense command simulator
COPY pfsense-shell /usr/local/bin/pfsense-shell
RUN chmod +x /usr/local/bin/pfsense-shell && \
    chsh -s /usr/local/bin/pfsense-shell root

# Entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
