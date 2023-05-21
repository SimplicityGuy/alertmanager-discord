FROM golang:alpine as builder

RUN apk update && \
    apk add ca-certificates git && \
    adduser -D -g '' appuser

COPY . $GOPATH/src/mypackage/myapp/
WORKDIR $GOPATH/src/mypackage/myapp/

RUN go get -d -v

RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -ldflags="-w -s" -o /go/bin/alertmanager-discord


FROM scratch

ENV LISTEN_ADDRESS=0.0.0.0:9094

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /go/bin/alertmanager-discord /go/bin/alertmanager-discord

EXPOSE 9094

USER appuser

ENTRYPOINT ["/go/bin/alertmanager-discord"]
