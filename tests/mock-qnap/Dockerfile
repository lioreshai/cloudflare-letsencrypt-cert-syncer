FROM alpine:3.19

# Mock QNAP SSH server for testing cert-push script
# Responds to QNAP-style commands with sudo simulation

RUN apk add --no-cache openssh-server openssl bash

# Create user for QNAP access
RUN adduser -D -s /usr/local/bin/qnap-shell qnap && \
    passwd -u qnap && \
    mkdir -p /home/qnap/.ssh && \
    chmod 700 /home/qnap/.ssh && \
    chown -R qnap:qnap /home/qnap

# SSH configuration
RUN ssh-keygen -A && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    echo "AllowUsers qnap" >> /etc/ssh/sshd_config

# Create state directory and simulated cert path
RUN mkdir -p /state /etc/stunnel && \
    chown qnap:qnap /state /etc/stunnel && \
    chmod 777 /state /etc/stunnel

# Install QNAP command simulator
COPY qnap-shell /usr/local/bin/qnap-shell
RUN chmod +x /usr/local/bin/qnap-shell

# Entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22

CMD ["/entrypoint.sh"]
