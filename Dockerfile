FROM golang:alpine AS builder

LABEL org.opencontainers.image.title="alertmanager-discord builder" \
      org.opencontainers.image.description="alertmanager-discord builder" \
      org.opencontainers.image.authors="robert@simplicityguy.com" \
      org.opencontainers.image.source="https://github.com/SimplicityGuy/alertmanager-discord/blob/main/Dockerfile" \
      org.opencontainers.image.licenses="Apache" \
      org.opencontainers.image.created="$(date +'%Y-%m-%d')" \
      org.opencontainers.image.base.name="docker.io/library/golang:alpine"

# hadolint ignore=DL3018
RUN apk update --quiet && \
    apk upgrade --quiet && \
    apk add --quiet --no-cache \
        ca-certificates \
        git && \
    rm /var/cache/apk/* && \
    adduser -D -g '' notifier

COPY . $GOPATH/src/alertmanager-discord/
WORKDIR $GOPATH/src/alertmanager-discord/

RUN go get -d -v && \
    CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -ldflags="-w -s" -o /go/bin/alertmanager-discord

FROM scratch

LABEL org.opencontainers.image.title="alertmanager-discord" \
      org.opencontainers.image.description="Take your alertmanager alerts, into discord." \
      org.opencontainers.image.authors="robert@simplicityguy.com" \
      org.opencontainers.image.source="https://github.com/SimplicityGuy/alertmanager-discord/blob/main/Dockerfile" \
      org.opencontainers.image.licenses="Apache" \
      org.opencontainers.image.created="$(date +'%Y-%m-%d')" \
      org.opencontainers.image.base.name="docker.io/library/scratch"

ENV LISTEN_ADDRESS=0.0.0.0:9094

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /go/bin/alertmanager-discord /go/bin/alertmanager-discord

EXPOSE 9094

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/go/bin/alertmanager-discord", "-healthcheck"]

USER notifier

ENTRYPOINT ["/go/bin/alertmanager-discord"]
