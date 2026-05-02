#!/usr/bin/env bash

# update-project.sh - Comprehensive project dependency and version updater
#
# Updates:
# - Go module dependencies (go get -u / go get -u=patch + go mod tidy)
# - Go version across go.mod, Dockerfile, and .github/workflows/*.yml
# - Pre-commit hooks (pre-commit autoupdate)
#
# Used by both developers locally and the update-dependencies GitHub
# workflow. The workflow passes --ci so the script emits GITHUB_OUTPUT
# values and writes deps-before.txt, deps-after.txt, and
# change-summary.md for downstream PR generation.
#
# Usage: ./scripts/update-project.sh [options]
#
# Options:
#   --go-version VERSION   Update Go version (e.g. 1.21 or 1.21.5)
#   --major                Include major version upgrades (go get -u)
#                          Without this flag, only patch+minor (go get -u=patch)
#   --no-backup            Skip creating backup files
#   --dry-run              Show what would be updated without making changes
#   --skip-tests           Skip running tests after updates
#   --ci                   Emit GITHUB_OUTPUT values, no backups, no prompts
#   --help                 Show this help message

set -euo pipefail

# Defaults
BACKUP=true
DRY_RUN=false
MAJOR_UPGRADES=false
SKIP_TESTS=false
UPDATE_GO=false
NEW_GO_VERSION=""
CI_MODE=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CHANGES_MADE=false

# Output formatting
print_info() { echo "ℹ️  [INFO] $1"; }
print_success() { echo "✅ [SUCCESS] $1"; }
print_warning() { echo "⚠️  [WARNING] $1"; }
print_error() { echo "❌ [ERROR] $1" >&2; }
print_section() {
  echo ""
  echo "━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

show_help() {
  sed -n '3,26p' "$0" | sed 's/^# \?//'
  exit 0
}

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --go-version)
      UPDATE_GO=true
      NEW_GO_VERSION="$2"
      shift 2
      ;;
    --major)
      MAJOR_UPGRADES=true
      shift
      ;;
    --no-backup)
      BACKUP=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=true
      shift
      ;;
    --ci)
      CI_MODE=true
      BACKUP=false
      shift
      ;;
    --help | -h)
      show_help
      ;;
    *)
      print_error "Unknown option: $1"
      show_help
      ;;
  esac
done

# Validate Go version format if provided
if [[ "$UPDATE_GO" == true ]]; then
  if ! [[ "$NEW_GO_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    print_error "Invalid Go version: $NEW_GO_VERSION (expected X.Y or X.Y.Z)"
    exit 1
  fi
fi

# Must be run from project root (where go.mod lives)
if [[ ! -f "go.mod" ]]; then
  print_error "Must be run from the project root (no go.mod found)"
  exit 1
fi

# Required tools
for tool in go git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    print_error "$tool is not installed"
    exit 1
  fi
done

# Backup setup
BACKUP_DIR="backups/project-updates-${TIMESTAMP}"
if [[ "$BACKUP" == true ]] && [[ "$DRY_RUN" == false ]]; then
  mkdir -p "$BACKUP_DIR"
  print_info "💾 Backups will be written to $BACKUP_DIR/"
fi

backup_file() {
  local file=$1
  if [[ "$BACKUP" == true ]] && [[ -f "$file" ]] && [[ "$DRY_RUN" == false ]]; then
    local dest_dir
    dest_dir="$BACKUP_DIR/$(dirname "$file")"
    mkdir -p "$dest_dir"
    cp "$file" "$dest_dir/$(basename "$file").backup"
  fi
}

# Cross-platform sed -i wrapper
sed_inplace() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Emit a key=value pair to GITHUB_OUTPUT (CI mode only)
emit_ci_output() {
  if [[ "$CI_MODE" == true ]] && [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "$1=$2" >> "$GITHUB_OUTPUT"
  fi
}

# Capture pre-update snapshot
capture_pre_snapshot() {
  print_section "📊 Pre-update snapshot"

  CURRENT_GO_VERSION=$(go version | awk '{print $3}')
  CURRENT_DEPS=$(go list -m all 2>/dev/null | grep -c . || echo 0)

  print_info "Current Go runtime: $CURRENT_GO_VERSION"
  print_info "Current dependency count: $CURRENT_DEPS"

  if [[ "$DRY_RUN" == false ]]; then
    go list -m all > deps-before.txt 2>/dev/null || echo "" > deps-before.txt
  fi

  emit_ci_output "current_go_version" "$CURRENT_GO_VERSION"
  emit_ci_output "current_deps" "$CURRENT_DEPS"
}

# Update Go version across files
update_go_version() {
  if [[ "$UPDATE_GO" != true ]]; then
    return
  fi

  print_section "🐹 Updating Go version to $NEW_GO_VERSION"

  # go.mod (uses major.minor only)
  local mod_version="${NEW_GO_VERSION%.*}"
  if grep -qE "^go [0-9]+\.[0-9]+" go.mod; then
    if [[ "$DRY_RUN" == false ]]; then
      backup_file go.mod
      sed_inplace "s/^go [0-9]\{1,\}\.[0-9]\{1,\}\(\.[0-9]\{1,\}\)\{0,1\}/go $mod_version/" go.mod
      print_success "Updated go.mod → go $mod_version"
      CHANGES_MADE=true
    else
      print_info "[DRY RUN] Would update go.mod → go $mod_version"
    fi
  fi

  # Dockerfile (ARG GO_VERSION=X.Y)
  if [[ -f Dockerfile ]] && grep -q "^ARG GO_VERSION=" Dockerfile; then
    if [[ "$DRY_RUN" == false ]]; then
      backup_file Dockerfile
      sed_inplace "s/^ARG GO_VERSION=[0-9.]*/ARG GO_VERSION=$NEW_GO_VERSION/" Dockerfile
      print_success "Updated Dockerfile → ARG GO_VERSION=$NEW_GO_VERSION"
      CHANGES_MADE=true
    else
      print_info "[DRY RUN] Would update Dockerfile → ARG GO_VERSION=$NEW_GO_VERSION"
    fi
  fi

  # GitHub workflows (env: GO_VERSION: '...')
  for wf in .github/workflows/*.yml; do
    [[ -f "$wf" ]] || continue
    if grep -qE "GO_VERSION: ['\"]?[0-9.]+['\"]?" "$wf"; then
      if [[ "$DRY_RUN" == false ]]; then
        backup_file "$wf"
        sed_inplace "s/GO_VERSION: '[0-9.]*'/GO_VERSION: '$NEW_GO_VERSION'/g" "$wf"
        sed_inplace "s/GO_VERSION: \"[0-9.]*\"/GO_VERSION: \"$NEW_GO_VERSION\"/g" "$wf"
        print_success "Updated $(basename "$wf") → GO_VERSION='$NEW_GO_VERSION'"
        CHANGES_MADE=true
      else
        print_info "[DRY RUN] Would update $(basename "$wf") → GO_VERSION='$NEW_GO_VERSION'"
      fi
    fi
  done
}

# Update Go module dependencies
update_go_deps() {
  print_section "📦 Updating Go module dependencies"

  if [[ "$MAJOR_UPGRADES" == true ]]; then
    print_info "Strategy: major+minor+patch (go get -u ./...)"
  else
    print_info "Strategy: patch+minor only (go get -u=patch ./...)"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$MAJOR_UPGRADES" == true ]]; then
      print_info "[DRY RUN] Would run: go get -u ./... && go mod tidy && go mod verify"
    else
      print_info "[DRY RUN] Would run: go get -u=patch ./... && go mod tidy && go mod verify"
    fi
    return
  fi

  backup_file go.mod
  [[ -f go.sum ]] && backup_file go.sum

  if [[ "$MAJOR_UPGRADES" == true ]]; then
    go get -u ./... 2>&1 || print_warning "go get -u reported issues (may be fine for std-lib-only projects)"
  else
    go get -u=patch ./... 2>&1 || print_warning "go get -u=patch reported issues"
  fi

  print_info "Tidying go.mod / go.sum..."
  go mod tidy

  print_info "Verifying modules..."
  go mod verify || print_warning "go mod verify failed"

  print_success "Go dependency update complete"
}

# Update pre-commit hooks
update_precommit_hooks() {
  print_section "🪝 Updating pre-commit hooks"

  if [[ ! -f .pre-commit-config.yaml ]]; then
    print_info "No .pre-commit-config.yaml found, skipping"
    return
  fi

  if ! command -v pre-commit >/dev/null 2>&1; then
    print_warning "pre-commit not installed locally, skipping hook updates"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    print_info "[DRY RUN] Would run: pre-commit autoupdate --freeze"
    return
  fi

  backup_file .pre-commit-config.yaml

  if pre-commit autoupdate --freeze; then
    print_success "Pre-commit hooks updated"
    if ! git diff --quiet .pre-commit-config.yaml 2>/dev/null; then
      CHANGES_MADE=true
    fi
  else
    print_warning "pre-commit autoupdate failed"
  fi
}

# Analyze what changed and produce summary artifacts
analyze_changes() {
  print_section "🔍 Analyzing changes"

  local mod_changed=false sum_changed=false
  if ! git diff --quiet go.mod 2>/dev/null; then
    mod_changed=true
    CHANGES_MADE=true
  fi
  if [[ -f go.sum ]] && ! git diff --quiet go.sum 2>/dev/null; then
    sum_changed=true
    CHANGES_MADE=true
  fi

  if [[ "$mod_changed" == false ]] && [[ "$sum_changed" == false ]]; then
    print_info "No dependency changes detected in go.mod/go.sum"
    emit_ci_output "no_changes" "true"
    emit_ci_output "direct_changes" "0"
    emit_ci_output "new_deps" "$CURRENT_DEPS"

    if [[ "$DRY_RUN" == false ]]; then
      cp deps-before.txt deps-after.txt 2>/dev/null || true
      {
        echo "## Dependency Changes"
        echo ""
        echo "_No changes detected._"
      } > change-summary.md
    fi
    return
  fi

  emit_ci_output "no_changes" "false"

  local new_deps=0
  new_deps=$(go list -m all 2>/dev/null | grep -c . || echo 0)
  emit_ci_output "new_deps" "$new_deps"

  if [[ "$DRY_RUN" == false ]]; then
    go list -m all > deps-after.txt 2>/dev/null || echo "" > deps-after.txt
  fi

  # Count direct dep changes from go.mod diff (lines that aren't headers, module/go directives)
  local direct_changes=0
  direct_changes=$(git diff go.mod 2>/dev/null \
    | grep -E '^[+-]' \
    | grep -vE '^(\+\+\+|---)' \
    | grep -vE '^[+-](module |go |require \(|\)|$)' \
    | grep -c . || true)
  emit_ci_output "direct_changes" "$direct_changes"

  print_info "Direct dependency changes: $direct_changes"
  print_info "Total deps before → after: $CURRENT_DEPS → $new_deps"

  if [[ "$DRY_RUN" == false ]]; then
    {
      echo "## Dependency Changes"
      echo ""
      echo "### Modified Direct Dependencies"
      echo ""
      git diff go.mod 2>/dev/null \
        | grep -E '^[+-]' \
        | grep -vE '^(\+\+\+|---)' \
        | grep -vE '^[+-](module |go |require \(|\)|$)' \
        | sed 's/^+/✅ Added\/Updated: /' \
        | sed 's/^-/❌ Removed\/Downgraded: /' \
        || echo "_(none)_"
      echo ""
      echo "### Summary"
      echo ""
      echo "- Total dependencies before: $CURRENT_DEPS"
      echo "- Total dependencies after: $new_deps"
      echo "- Direct dependency changes: $direct_changes"
    } > change-summary.md
  fi
}

# Run tests
run_tests() {
  if [[ "$SKIP_TESTS" == true ]] || [[ "$DRY_RUN" == true ]]; then
    return
  fi

  print_section "🧪 Running tests"

  if go test -v ./...; then
    print_success "Tests passed"
  else
    print_error "Tests failed"
    exit 1
  fi
}

# Print summary
generate_summary() {
  print_section "📝 Summary"

  if [[ "$DRY_RUN" == true ]]; then
    print_info "Dry run complete — no changes applied"
    return
  fi

  if [[ "$CHANGES_MADE" == false ]]; then
    print_success "Everything already up to date"
    return
  fi

  echo ""
  echo "Files potentially modified:"
  git diff --stat 2>/dev/null || true

  if [[ "$BACKUP" == true ]] && [[ -d "$BACKUP_DIR" ]]; then
    echo ""
    print_info "Backups: $BACKUP_DIR/"
    print_info "  Restore go.mod: cp $BACKUP_DIR/go.mod.backup go.mod && go mod tidy"
  fi

  echo ""
  echo "Next steps:"
  echo "  git diff           # review changes"
  echo "  git add -p         # stage selectively"
  echo "  git commit -m \"chore(deps): update Go dependencies\""
}

# Main
main() {
  print_section "🚀 alertmanager-discord project update"

  capture_pre_snapshot
  update_go_version
  update_go_deps
  update_precommit_hooks
  analyze_changes
  run_tests
  generate_summary
}

main
