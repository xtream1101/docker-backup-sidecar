# Docker Backup Sidecar - Task Automation

# Show all available tasks
default:
    @just --list

# === Testing ===

# Run full test suite (all tests)
test:
    ./test.sh all

# Run quick smoke tests (environment + scripts only)
test-quick:
    ./test.sh environment && ./test.sh scripts

# Test backup functionality only
test-backup:
    ./test.sh backup

# Test restore functionality only
test-restore:
    ./test.sh restore

# Test environment setup only
test-env:
    ./test.sh environment

# Test file backup functionality
test-files:
    ./test.sh files

# Test encryption functionality
test-encryption:
    ./test.sh encryption

# Test container stop/start during backup
test-stop-services:
    ./test.sh stop-services

# === Development ===

# Build the backup container image
build:
    docker compose -f docker-compose.example.yml build

# Start the test environment
up:
    docker compose -f docker-compose.example.yml up -d
    @echo "Waiting for services to be ready..."
    @sleep 5
    @docker compose -f docker-compose.example.yml ps

# Stop and clean test environment (removes volumes)
down:
    docker compose -f docker-compose.example.yml down -v

# View backup container logs (follow mode)
logs:
    docker compose -f docker-compose.example.yml logs backup -f

# Full cleanup (stop services, remove volumes and backups)
clean:
    docker compose -f docker-compose.example.yml down -v
    rm -rf test-backups/
    @echo "Cleanup complete"

# === Manual Operations ===

# Run a manual backup now
backup:
    docker compose -f docker-compose.example.yml exec backup /backup-scripts/backup-now.sh

# List all available backups
list:
    docker compose -f docker-compose.example.yml exec backup /backup-scripts/list-backups.sh

# Interactive restore from backup
restore:
    docker compose -f docker-compose.example.yml exec backup /backup-scripts/restore.sh

# === Linting & Quality ===

# Run shellcheck on all scripts
lint:
    @echo "Running shellcheck on scripts..."
    @shellcheck scripts/*.sh test.sh init-test-postgres.sh || echo "shellcheck not installed - install via: apt-get install shellcheck"

# Format shell scripts (requires shfmt)
format:
    @echo "Formatting shell scripts..."
    @shfmt -w -i 4 -ci scripts/*.sh test.sh || echo "shfmt not installed - install via: go install mvdan.cc/sh/v3/cmd/shfmt@latest"
