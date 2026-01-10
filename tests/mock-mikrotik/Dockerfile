FROM alpine:3.19

# Mock MikroTik SSH server for testing cert-push script
# Responds to MikroTik-style commands and stores certificate state

RUN apk add --no-cache openssh-server openssl bash

# Create user for cert-push
RUN adduser -D -s /usr/local/bin/mikrotik-shell cert-push && \
    passwd -u cert-push && \
    mkdir -p /home/cert-push/.ssh && \
    chmod 700 /home/cert-push/.ssh && \
    chown -R cert-push:cert-push /home/cert-push

# SSH configuration
RUN ssh-keygen -A && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    echo "AllowUsers cert-push" >> /etc/ssh/sshd_config

# Create state directory for certificate tracking
RUN mkdir -p /state /files && \
    chown cert-push:cert-push /state /files

# Install MikroTik command simulator
COPY mikrotik-shell /usr/local/bin/mikrotik-shell
RUN chmod +x /usr/local/bin/mikrotik-shell

# Entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
