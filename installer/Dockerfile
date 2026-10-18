FROM alpine:3.20
RUN apk add --no-cache bash curl jq docker-cli docker-cli-compose
COPY install.sh /install.sh
RUN chmod +x /install.sh
ENTRYPOINT ["/install.sh"]
