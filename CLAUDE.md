# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

alertmanager-discord is a lightweight Go webhook service that receives alerts from Prometheus Alertmanager and forwards them to Discord channels via webhooks. This is **NOT** a replacement for Alertmanager - it's a webhook target that sits downstream of Alertmanager in the monitoring pipeline.

**Critical Data Flow:**

```
Prometheus → Alertmanager → alertmanager-discord → Discord
```

The service **must** receive alerts from Alertmanager, not directly from Prometheus. Direct Prometheus alerts will trigger a misconfiguration warning (see `detect-misconfig.go`).

## Architecture

### Core Components

**main.go** - Main service with three responsibilities:

1. **Webhook receiver** - HTTP server listening on `LISTEN_ADDRESS` (default: `127.0.0.1:9094`)
1. **Alert parser** - Unmarshals Alertmanager JSON into `alertManOut` structure
1. **Discord formatter** - Transforms alerts into Discord embeds with color coding:
   - `firing` alerts → Red (0x992D22)
   - `resolved` alerts → Green (0x2ECC71)
   - Unknown status → Grey (0x95A5A6)

**detect-misconfig.go** - Validates incoming payloads:

- Detects raw Prometheus alerts (missing Alertmanager wrapper)
- Sends educational Discord message when misconfigured
- Prevents confusion when service is directly connected to Prometheus

### Key Design Decisions

**HTTP multiplexer pattern**: Uses `http.NewServeMux()` for routing multiple endpoints (main.go:237):

- `GET /health` - Health check endpoint returning `{"status":"ok"}`
- `POST /` - Webhook handler for Alertmanager alerts

**Scratch-based Docker image**: The production container uses `FROM scratch` for minimal attack surface. This means:

- No shell, no debugging tools in production image
- Health checks implemented using `-healthcheck` flag in the Go binary
- Binary performs self-test via HTTP GET to `/health` endpoint
- CA certificates and user copied from builder stage

**Grouped alerts**: The `sendWebhook()` function groups alerts by status before sending to Discord, ensuring one Discord message per status type (firing/resolved) rather than per individual alert.

## Development Commands

### Build

**Local development build:**

```bash
go build -o alertmanager-discord
```

**Platform-specific builds:**

```bash
# macOS
GOOS=darwin go build -o alertmanager-discord.darwin

# Linux
GOOS=linux go build -o alertmanager-discord.linux
```

**Docker multi-platform build:**

```bash
docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6 -t alertmanager-discord .
```

The CI/CD workflow (`.github/workflows/build.yml`) automatically builds for all four platforms and publishes to GitHub Container Registry.

### Linting

```bash
# Run all pre-commit hooks (includes golangci-lint, hadolint, etc.)
pre-commit run --all-files

# Run only Go linting
pre-commit run golangci-lint --all-files

# Run only Dockerfile linting
pre-commit run hadolint --all-files
```

Pre-commit hooks are **required** and enforce:

- Go code quality (golangci-lint)
- Dockerfile best practices (hadolint)
- Markdown formatting (mdformat with GFM support)
- Secret detection (AWS credentials, private keys)
- YAML validation for GitHub workflows

### Running Locally

```bash
# Set Discord webhook URL
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."

# Run with default listen address (127.0.0.1:9094)
./alertmanager-discord

# Run with custom listen address
export LISTEN_ADDRESS="0.0.0.0:9094"
./alertmanager-discord

# Or use CLI flags
./alertmanager-discord -webhook.url="https://discord.com/api/webhooks/..." -listen.address="0.0.0.0:9094"
```

**Testing with curl:**

```bash
# Send a sample Alertmanager webhook (must match alertManOut structure)
curl -X POST http://localhost:9094 \
  -H "Content-Type: application/json" \
  -d '{
    "alerts": [{
      "status": "firing",
      "labels": {"alertname": "TestAlert", "instance": "localhost"},
      "annotations": {"description": "Test alert description"}
    }],
    "commonLabels": {"alertname": "TestAlert"},
    "commonAnnotations": {"summary": "Test summary"}
  }'
```

## Configuration

### Environment Variables

- `DISCORD_WEBHOOK` - **Required**. Discord webhook URL. Must match pattern: `https://discord(?:app)?.com/api/webhooks/[0-9]{18,19}/[a-zA-Z0-9_-]+`
- `LISTEN_ADDRESS` - Optional. Format: `host:port`. Default: `127.0.0.1:9094`

### CLI Flags

- `-webhook.url` - Alternative to `DISCORD_WEBHOOK` environment variable
- `-listen.address` - Alternative to `LISTEN_ADDRESS` environment variable
- `-healthcheck` - Perform health check and exit (used by Docker HEALTHCHECK)

Environment variables take precedence over CLI flags if both are set.

### Health Checking

The service includes built-in health checking for containerized deployments:

**Health endpoint:**

```bash
curl http://localhost:9094/health
# Returns: {"status":"ok"}
```

**Docker health check:**
The Dockerfile includes a HEALTHCHECK instruction that runs every 30 seconds:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/go/bin/alertmanager-discord", "-healthcheck"]
```

When run with `-healthcheck`, the binary performs an HTTP GET to its own `/health` endpoint and exits with:

- Exit code 0: Service is healthy
- Exit code 1: Service is unhealthy

This works with the scratch-based image without requiring external tools.

## Testing Considerations

**No test files exist currently.** When adding tests:

- Mock the Discord webhook endpoint to avoid sending real messages
- Test the `isRawPromAlert()` detection logic with both Alertmanager and raw Prometheus payloads
- Validate alert grouping by status in `sendWebhook()`
- Test URL validation in `checkWhURL()`

## Docker Deployment

**Production image:** `ghcr.io/simplicityguy/alertmanager-discord:latest`

The Dockerfile uses multi-stage build:

1. **Builder stage**: Alpine-based Go build environment with CA certs and non-root user creation
1. **Production stage**: Scratch image with only the compiled binary, certs, and passwd file

**Health checking:** The image includes Docker HEALTHCHECK using the `-healthcheck` flag. The binary performs self-tests via the `/health` endpoint without requiring external tools in the scratch image.

## Common Pitfalls

1. **Connecting Prometheus directly to this service** - Will trigger misconfiguration warning. Always go through Alertmanager.
1. **Invalid Discord webhook URL** - Service validates URL format at startup and will fatal if invalid.
1. **Assuming scratch image has debugging tools** - It doesn't. Debug in the builder stage or locally.
1. **Expecting individual alerts per Discord message** - Alerts are grouped by status (firing/resolved) before sending.

## Module Information

- **Module path**: `github.com/benjojo/alertmanager-discord`
- **Go version**: 1.20
- **No external dependencies** (uses only Go standard library)
