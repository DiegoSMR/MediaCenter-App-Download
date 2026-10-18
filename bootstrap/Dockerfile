FROM alpine:3.20
RUN apk add --no-cache bash curl jq
COPY common.sh /common.sh
COPY bootstrap.sh /bootstrap.sh
COPY firstrun.sh /firstrun.sh
COPY assets/homer /assets/homer
RUN chmod +x /bootstrap.sh /firstrun.sh
ENTRYPOINT ["/bootstrap.sh"]
