FROM alpine:3.20
RUN apk add --no-cache bash rsync
COPY backup.sh /backup.sh
RUN chmod +x /backup.sh
ENTRYPOINT ["/backup.sh"]
