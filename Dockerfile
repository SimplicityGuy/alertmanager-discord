# Build arguments
ARG GO_VERSION=1.20
ARG BUILD_DATE
ARG BUILD_VERSION
ARG VCS_REF

FROM golang:${GO_VERSION}-alpine AS builder

# Re-declare args after FROM to make them available in this stage
ARG BUILD_DATE
ARG BUILD_VERSION
ARG VCS_REF

LABEL org.opencontainers.image.title="alertmanager-discord builder" \
      org.opencontainers.image.description="alertmanager-discord builder" \
      org.opencontainers.image.authors="robert@simplicityguy.com" \
      org.opencontainers.image.source="https://github.com/SimplicityGuy/alertmanager-discord" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="docker.io/library/golang:${GO_VERSION}-alpine"

# hadolint ignore=DL3018
RUN apk update --quiet && \
    apk upgrade --quiet && \
    apk add --quiet --no-cache \
        ca-certificates \
        git && \
    rm -rf /var/cache/apk/* && \
    adduser -D -g '' notifier

COPY . $GOPATH/src/alertmanager-discord/
WORKDIR $GOPATH/src/alertmanager-discord/

# Build with version information embedded
RUN go get -d -v && \
    CGO_ENABLED=0 GOOS=linux go build \
        -a -installsuffix cgo \
        -ldflags="-w -s -X main.Version=${BUILD_VERSION} -X main.Revision=${VCS_REF} -X main.BuildDate=${BUILD_DATE}" \
        -o /go/bin/alertmanager-discord

FROM scratch

# Re-declare args for final stage
ARG BUILD_DATE
ARG BUILD_VERSION
ARG VCS_REF

LABEL org.opencontainers.image.title="alertmanager-discord" \
      org.opencontainers.image.description="Take your alertmanager alerts, into discord." \
      org.opencontainers.image.authors="robert@simplicityguy.com" \
      org.opencontainers.image.source="https://github.com/SimplicityGuy/alertmanager-discord" \
      org.opencontainers.image.documentation="https://github.com/SimplicityGuy/alertmanager-discord/blob/main/README.md" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="scratch"

ENV LISTEN_ADDRESS=0.0.0.0:9094

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /go/bin/alertmanager-discord /go/bin/alertmanager-discord

EXPOSE 9094

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/go/bin/alertmanager-discord", "-healthcheck"]

USER notifier

ENTRYPOINT ["/go/bin/alertmanager-discord"]
