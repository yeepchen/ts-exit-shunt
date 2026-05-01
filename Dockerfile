FROM tailscale/tailscale:latest

USER root
COPY init.sh /usr/local/bin/ts-init.sh
RUN chmod +x /usr/local/bin/ts-init.sh

ENTRYPOINT ["/usr/local/bin/ts-init.sh"]
