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

# Windows
GOOS=windows go build -o alertmanager-discord.windows
```

**Docker multi-platform build:**

```bash
docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6 -t alertmanager-discord .
```

The CI/CD workflow (`.github/workflows/build.yml`) automatically builds for all four platforms and publishes to GitHub Container Registry.

### Testing

```bash
# Run all tests
go test -v ./...

# Run tests with coverage
go test -v -race -coverprofile=coverage.out -covermode=atomic ./...

# View coverage report in browser
go tool cover -html=coverage.out

# Run benchmarks
go test -bench=. -benchmem ./...

# Run only fast tests (with -short flag)
go test -short ./...
```

### Linting and Code Quality

```bash
# Run all pre-commit hooks (includes golangci-lint, hadolint, etc.)
pre-commit run --all-files

# Run only Go linting
pre-commit run golangci-lint --all-files

# Run only Go formatting check
pre-commit run go-fmt --all-files

# Run only Go vet
pre-commit run go-vet --all-files

# Run only Dockerfile linting
pre-commit run hadolint --all-files

# Run only YAML linting
pre-commit run yamllint --all-files

# Run only shell script checks
pre-commit run shellcheck --all-files

# Run only markdown formatting
pre-commit run mdformat --all-files
```

Pre-commit hooks are **required** and enforce:

- **Go**: golangci-lint, gofmt, go vet, go mod tidy (handles missing go.sum gracefully)
- **Docker**: hadolint
- **GitHub Actions**: actionlint (ignores SC2129), check-github-workflows
- **YAML**: yamllint (strict mode with 175 char line length warning)
- **Shell**: shellcheck (warning severity), shfmt (2-space indent)
- **Markdown**: mdformat with GFM and tables support
- **Security**: detect-aws-credentials, detect-private-key
- **General**: trailing-whitespace, end-of-file-fixer, mixed-line-ending

**Note**: The `go-mod-tidy` hook gracefully handles projects without `go.sum` files, making it safe for standard library-only projects.

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

# Test health check endpoint
curl http://localhost:9094/health
```

## Configuration

### Environment Variables

- `DISCORD_WEBHOOK` - **Required**. Discord webhook URL. Must match pattern: `https://discord(?:app)?.com/api/webhooks/[0-9]{18,19}/[a-zA-Z0-9_-]+`
- `LISTEN_ADDRESS` - Optional. Format: `host:port`. Default: `127.0.0.1:9094`
- `GO_VERSION` - Set in CI/CD workflows. Default: `1.20`

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

## CI/CD Workflows

The project uses GitHub Actions for comprehensive CI/CD automation. All workflows use centralized `GO_VERSION` environment variable.

### Core Workflows

**code-quality.yml** - Runs on push/PR to main, triggered by Go/Docker/workflow file changes:

- **pre-commit job**: Runs all pre-commit hooks (markdown, security, YAML)
- **golangci-lint job**: Comprehensive Go linting with caching
- **go-fmt job**: Go formatting and `go vet` checks
- All jobs run in parallel for fast feedback
- Includes timer tracking and Discord notifications

**test.yml** - Runs on push/PR to main, triggered by Go file changes:

- **go-test job**: Unit tests with race detection and coverage
  - Intelligent test skipping for PRs without Go changes
  - Codecov integration with PR comments
  - Coverage artifacts (HTML, XML, out) with 30-day retention
  - Test count metrics
- **benchmark job**: Performance benchmarking
  - Auto-detects if benchmarks exist
  - Compares with previous runs on PRs
  - 90-day artifact retention
- Both jobs run in parallel

**docker-validate.yml** - Runs on Docker/Go file changes:

- **validate-dockerfile**: hadolint validation
- **test-docker-build**: Tests both builder and final stages
  - Security checks (non-root user, health check, ports)
  - Image inspection (labels, size, layers)
  - Matrix strategy for parallel testing
- **validate-dockerignore**: Ensures .dockerignore exists and has common exclusions

**build.yml** - Runs on push to main, schedule, and manual trigger:

- Calls code-quality.yml and test.yml first (must pass)
- Only runs if tests pass
- Multi-platform Docker build (amd64, arm64, arm/v7, arm/v6)
- Pushes to GitHub Container Registry
- Includes disk space management and cleanup
- Metrics collection and Discord notifications
- Uses build arguments for versioning (GO_VERSION, BUILD_DATE, VCS_REF)

### Automation Workflows

**update-dependencies.yml** - Runs weekly Monday 9am UTC, manual trigger:

- Two update strategies: conservative (default) or aggressive (opt-in)
- Optional Go version updates across all workflows and Dockerfile
- Pre-update dependency snapshots
- Runs tests before creating PR
- Comprehensive PR with before/after comparison
- Security validation with `go mod verify`
- 20-minute timeout protection
- **Shellcheck compliant**: Uses `grep -c` instead of `wc -l`, proper variable expansion
- **Yamllint compliant**: Long lines split with backslashes (\<175 chars)

**cleanup-cache.yml** - Runs when PR is closed:

- Removes all caches associated with the closed PR
- Prevents cache storage buildup
- Graceful handling if no caches found
- 10-minute timeout

**cleanup-images.yml** - Runs monthly on 15th, manual trigger:

- Uses dataaxiom/ghcr-cleanup-action
- Keeps last 3 tagged images
- Deletes images older than 30 days
- Removes untagged and partial images
- No special token required (uses GITHUB_TOKEN)
- 30-minute timeout

### Workflow Features

**Common Patterns:**

- ⏱️ Timer tracking for all jobs
- 📊 Metrics collection and GitHub notices
- 📢 Discord notifications with detailed status
- 💾 Enhanced caching strategies
- 🎯 Path-based triggering for efficiency
- ⏰ Timeout protection on all jobs
- 🏷️ Emoji prefixes for better log scanning

**Smart Optimizations:**

- Path filtering to skip unnecessary runs
- Intelligent test skipping for doc-only PRs
- Parallel job execution where possible
- Multi-stage Docker builds with caching
- Artifact retention policies (30-90 days)

### Code Quality Compliance

All workflows and configuration files comply with strict quality standards:

**Shellcheck Compliance (SC2126, SC2309):**

- Use `grep -c .` instead of `wc -l | grep` for line counting
- Proper variable expansion before numeric comparisons (`-gt`, `-lt`, etc.)
- Extract GitHub Action outputs to shell variables before conditionals

**Yamllint Compliance:**

- All YAML files start with `---` document marker
- Lines kept under 175 characters (warning threshold)
- Long lines split using backslash continuations
- Strict mode enabled with pragmatic exceptions

**Pre-commit Hook Robustness:**

- `go-mod-tidy` hook handles missing `go.sum` files gracefully
- Conditional file checking with `test -f` before operations
- Safe for standard library-only projects

## Testing Considerations

**Current state:** No test files exist currently.

**When adding tests, consider:**

- Mock the Discord webhook endpoint to avoid sending real messages during tests
- Test the `isRawPromAlert()` detection logic with both Alertmanager and raw Prometheus payloads
- Validate alert grouping by status in `sendWebhook()`
- Test URL validation in `checkWhURL()`
- Add benchmarks for performance-critical code paths
- Use table-driven tests for multiple test cases
- Aim for >80% code coverage
- Use `-short` flag for fast tests in pre-commit hooks

**Testing best practices:**

```go
// Example table-driven test
func TestAlertParsing(t *testing.T) {
    tests := []struct {
        name    string
        input   string
        want    alertManOut
        wantErr bool
    }{
        // test cases...
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            // test implementation...
        })
    }
}
```

## Docker Deployment

**Production image:** `ghcr.io/simplicityguy/alertmanager-discord:latest`

The Dockerfile uses multi-stage build with build arguments:

1. **Builder stage**:

   - `golang:${GO_VERSION}-alpine` base
   - CA certificates and non-root user creation
   - Compiles with version information embedded via ldflags
   - Build args: GO_VERSION, BUILD_DATE, BUILD_VERSION, VCS_REF

1. **Production stage**:

   - Scratch image for minimal attack surface
   - Only compiled binary, certs, and passwd file
   - OCI image labels with build metadata
   - Runs as non-root user `notifier`

**Image features:**

- Multi-platform support (4 architectures)
- Health check using `-healthcheck` flag
- Version information embedded in binary
- Security: no shell, minimal dependencies, non-root user
- Size: \<10MB (scratch-based)

**Build arguments accepted:**

```dockerfile
ARG GO_VERSION=1.20
ARG BUILD_DATE
ARG BUILD_VERSION
ARG VCS_REF
```

## Common Pitfalls

1. **Connecting Prometheus directly to this service** - Will trigger misconfiguration warning. Always go through Alertmanager.
1. **Invalid Discord webhook URL** - Service validates URL format at startup and will fatal if invalid.
1. **Assuming scratch image has debugging tools** - It doesn't. Debug in the builder stage or locally.
1. **Expecting individual alerts per Discord message** - Alerts are grouped by status (firing/resolved) before sending.
1. **Forgetting to run pre-commit hooks** - Install with `pre-commit install` to run automatically on commit.
1. **Not updating GO_VERSION in all places** - Use the update-dependencies workflow to update all files consistently.
1. **Skipping tests** - The build workflow requires tests to pass before building Docker images.
1. **Shell script violations** - Use `grep -c .` instead of `wc -l` for counting lines (shellcheck SC2126).
1. **YAML line length** - Keep lines under 175 characters or split with backslashes (yamllint).
1. **Missing document start** - All YAML files must start with `---` (yamllint document-start rule).

## Module Information

- **Module path**: `github.com/benjojo/alertmanager-discord`
- **Go version**: 1.20 (centralized in workflow `GO_VERSION` env var)
- **No external dependencies** (uses only Go standard library)
- **License**: Apache-2.0

## File Structure

```
alertmanager-discord/
├── main.go                    # Main webhook service
├── detect-misconfig.go        # Misconfiguration detection
├── go.mod                     # Go module definition
├── Dockerfile                 # Multi-stage Docker build
├── .dockerignore              # Docker build exclusions
├── .gitignore                 # Git exclusions
├── .pre-commit-config.yaml    # Pre-commit hook configuration (26 hooks)
├── .yamllint                  # YAML linting rules (175 char limit)
├── README.md                  # User documentation
├── CLAUDE.md                  # This file (AI assistance guide)
├── LICENSE                    # Apache-2.0 license
├── .github/
│   ├── FUNDING.yml            # GitHub Sponsors configuration
│   └── workflows/
│       ├── build.yml          # Multi-platform Docker builds
│       ├── code-quality.yml   # Linting and formatting (3 jobs)
│       ├── test.yml           # Unit tests and benchmarks (2 jobs)
│       ├── docker-validate.yml # Docker validation (3 jobs)
│       ├── update-dependencies.yml # Automated dependency updates
│       ├── cleanup-cache.yml  # Cache cleanup on PR close
│       └── cleanup-images.yml # Monthly image cleanup
└── images/
    └── example.png            # Example Discord notification
```

## Development Workflow

1. **Clone and setup:**

   ```bash
   git clone https://github.com/SimplicityGuy/alertmanager-discord.git
   cd alertmanager-discord
   go mod download
   pre-commit install
   ```

1. **Make changes:**

   - Edit Go files
   - Pre-commit hooks run automatically on commit
   - Or run manually: `pre-commit run --all-files`

1. **Test locally:**

   ```bash
   go test -v ./...
   go build -o alertmanager-discord
   ./alertmanager-discord -webhook.url="..." -listen.address="0.0.0.0:9094"
   ```

1. **Push changes:**

   - Push to feature branch
   - Create PR to main
   - Workflows run automatically:
     - Code quality checks
     - Unit tests with coverage
     - Docker validation
   - Review Codecov report in PR
   - Merge when all checks pass

1. **Automated deployment:**

   - Build workflow runs on merge to main
   - Multi-platform images pushed to GHCR
   - Tagged with `latest` and git ref
   - Discord notification sent

## Quick Reference

**Most Common Commands:**

```bash
# Development
go run main.go detect-misconfig.go
go test -v ./...
pre-commit run --all-files

# Building
go build -o alertmanager-discord
docker build -t alertmanager-discord .

# Testing
curl -X POST http://localhost:9094 -H "Content-Type: application/json" -d '...'
curl http://localhost:9094/health

# Quality
gofmt -l -w .
go vet ./...
golangci-lint run --timeout=5m
```

**Environment Setup:**

```bash
export DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
export LISTEN_ADDRESS="0.0.0.0:9094"
export GO_VERSION="1.20"
```

**Docker Commands:**

```bash
# Run
docker run -p 9094:9094 -e DISCORD_WEBHOOK="..." ghcr.io/simplicityguy/alertmanager-discord:latest

# Health check
docker exec alertmanager-discord /go/bin/alertmanager-discord -healthcheck

# Logs
docker logs alertmanager-discord
```
