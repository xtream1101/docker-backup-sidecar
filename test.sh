#!/bin/bash
# Integration tests for docker-backup-sidecar
# Tests backup, restore, and core functionality

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Docker Compose file to use
COMPOSE_FILE="docker-compose.example.yml"
COMPOSE_CMD="docker compose -f ${COMPOSE_FILE}"

# Test directories
TEST_BACKUP_DIR="./test-backups"

# ==============================================================================
# Helper Functions
# ==============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

log_test() {
    echo -e "${BLUE}[TEST]${NC} $*"
}

# Assert that a command succeeds
assert_success() {
    local description="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))

    log_test "Testing: $description"

    if "$@" > /dev/null 2>&1; then
        log_success "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$description"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Assert that a command fails
assert_failure() {
    local description="$1"
    shift
    TESTS_RUN=$((TESTS_RUN + 1))

    log_test "Testing: $description"

    if ! "$@" > /dev/null 2>&1; then
        log_success "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$description"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Assert that a string contains another string
assert_contains() {
    local description="$1"
    local haystack="$2"
    local needle="$3"
    TESTS_RUN=$((TESTS_RUN + 1))

    log_test "Testing: $description"

    if echo "$haystack" | grep -q "$needle"; then
        log_success "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$description (Expected to find: '$needle')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Assert that a file exists
assert_file_exists() {
    local description="$1"
    local file="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    log_test "Testing: $description"

    if [ -f "$file" ]; then
        log_success "$description"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        log_error "$description (File not found: $file)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Wait for a condition with timeout
wait_for() {
    local description="$1"
    local max_wait="$2"
    shift 2
    local waited=0

    log_info "Waiting for: $description (max ${max_wait}s)"

    while ! "$@" > /dev/null 2>&1; do
        if [ $waited -ge "$max_wait" ]; then
            log_error "Timeout waiting for: $description"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_success "Condition met: $description (${waited}s)"
    return 0
}

# ==============================================================================
# Setup and Teardown
# ==============================================================================

setup() {
    log_info "Setting up test environment..."

    # Clean up any existing test environment
    ${COMPOSE_CMD} down -v > /dev/null 2>&1 || true
    rm -rf "${TEST_BACKUP_DIR}" || true

    # Start services
    log_info "Starting services..."
    ${COMPOSE_CMD} up -d --build

    # Wait for services to be healthy (using docker compose ps to check health status)
    log_info "Waiting for services to be healthy (max 60s)..."
    local waited=0
    while [ $waited -lt 60 ]; do
        local postgres_health
        local mongo_health
        postgres_health=$(${COMPOSE_CMD} ps db --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d'"' -f4 || echo "starting")
        mongo_health=$(${COMPOSE_CMD} ps mongo --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | cut -d'"' -f4 || echo "starting")

        if [ "$postgres_health" = "healthy" ] && [ "$mongo_health" = "healthy" ]; then
            log_success "All services are healthy (${waited}s)"
            break
        fi

        sleep 1
        waited=$((waited + 1))
    done

    if [ $waited -ge 60 ]; then
        log_error "Services did not become healthy in time"
        ${COMPOSE_CMD} ps
        return 1
    fi

    # Additional wait to ensure databases are fully accepting connections
    # Health checks pass, but exec commands might not work immediately
    log_info "Waiting for databases to accept connections..."
    sleep 2

    # Give app container time to create initial data
    log_info "Waiting for app to generate initial data..."
    sleep 3

    log_success "Test environment ready"
}

teardown() {
    log_info "Tearing down test environment..."
    ${COMPOSE_CMD} down -v > /dev/null 2>&1 || true
    rm -rf "${TEST_BACKUP_DIR}" || true
    log_success "Cleanup complete"
}

# ==============================================================================
# Test Suites
# ==============================================================================

test_environment() {
    echo ""
    log_info "========================================="
    log_info "Test Suite: Environment"
    log_info "========================================="

    # Test that all containers are running
    local ps_output
    ps_output=$(${COMPOSE_CMD} ps --format json 2>/dev/null || echo "[]")

    assert_contains "Database container is running" \
        "$ps_output" "db"

    assert_contains "App container is running" \
        "$ps_output" "app"

    assert_contains "Backup container is running" \
        "$ps_output" "backup"

    assert_contains "MongoDB container is running" \
        "$ps_output" "mongo"

    # Test database connectivity
    assert_success "Can connect to PostgreSQL database" \
        "${COMPOSE_CMD}" exec -T db psql -U testuser -d testdb -c "SELECT 1"

    # Test MongoDB connectivity
    assert_success "Can connect to MongoDB database" \
        "${COMPOSE_CMD}" exec -T mongo mongosh --quiet --eval "db.adminCommand('ping')"

    # Test that sample data exists
    local user_count
    user_count=$(${COMPOSE_CMD} exec -T db psql -U testuser -d testdb -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')

    assert_contains "Sample users exist in PostgreSQL database" \
        "$user_count" "3"

    # Test MongoDB sample data
    local mongo_user_count
    mongo_user_count=$(${COMPOSE_CMD} exec -T mongo mongosh testdb -u testuser -p testpass123 --authenticationDatabase admin --quiet --eval "db.users.countDocuments()" 2>/dev/null | tail -1)

    assert_contains "Sample users exist in MongoDB database" \
        "$mongo_user_count" "3"    # Test that app is generating data
    assert_success "App data directory exists" \
        "${COMPOSE_CMD}" exec -T backup test -d /app/data

    assert_success "App log file exists" \
        "${COMPOSE_CMD}" exec -T backup test -f /app/data/app.log

    # Test directly mounted file exists
    assert_success "Config file exists (directly mounted)" \
        "${COMPOSE_CMD}" exec -T backup test -f /app/config.json

    # Verify config file content
    local config_content
    config_content=$(${COMPOSE_CMD} exec -T backup cat /app/config.json 2>/dev/null)

    assert_contains "Config file has correct content" \
        "$config_content" "settings"
}

test_backup() {
    echo ""
    log_info "========================================="
    log_info "Test Suite: Backup Functionality"
    log_info "========================================="

    # Test backup script exists and is executable
    assert_success "Backup script exists and is executable" \
        "${COMPOSE_CMD}" exec -T backup test -x /backup-scripts/backup-now.sh

    # Run a backup
    log_info "Running backup (this may take a few seconds)..."
    local backup_output
    backup_output=$(${COMPOSE_CMD} exec -T backup /backup-scripts/backup-now.sh 2>&1)

    assert_contains "Backup completes successfully" \
        "$backup_output" "Backup completed successfully"

    assert_contains "PostgreSQL database is backed up" \
        "$backup_output" "Backing up PostgreSQL database"

    assert_contains "MongoDB database is backed up" \
        "$backup_output" "Backing up MongoDB database"

    assert_contains "Directory is backed up" \
        "$backup_output" "Backing up directory"

    assert_contains "File is backed up" \
        "$backup_output" "Backing up file"

    assert_contains "Backup is encrypted" \
        "$backup_output" "Encrypting backup"

    # Check that backup file exists
    local backup_files
    backup_files=$(find "${TEST_BACKUP_DIR}" -name "*.tar.gz.gpg" 2>/dev/null || true)

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$backup_files" ]; then
        log_success "Backup file created: $(basename "$backup_files")"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "No backup file found in ${TEST_BACKUP_DIR}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Test list-backups script
    local list_output
    list_output=$(${COMPOSE_CMD} exec -T backup /backup-scripts/list-backups.sh 2>&1)

    assert_contains "List backups shows backup file" \
        "$list_output" "tar.gz.gpg"
}

test_restore() {
    echo ""
    log_info "========================================="
    log_info "Test Suite: Restore Functionality"
    log_info "========================================="

    # First, create a backup
    log_info "Creating initial backup..."
    ${COMPOSE_CMD} exec -T backup /backup-scripts/backup-now.sh > /dev/null 2>&1

    # Modify database data
    log_info "Modifying database data..."
    ${COMPOSE_CMD} exec -T db psql -U testuser -d testdb -c "INSERT INTO users (username, email) VALUES ('testuser', 'test@example.com');" > /dev/null 2>&1

    local users_before
    users_before=$(${COMPOSE_CMD} exec -T db psql -U testuser -d testdb -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')

    assert_contains "New user was added" \
        "$users_before" "4"

    # Test restore script exists
    assert_success "Restore script exists and is executable" \
        "${COMPOSE_CMD}" exec -T backup test -x /backup-scripts/restore.sh

    # Note: Full restore test requires interactive input or modification
    # For automated testing, we verify the restore script can be invoked
    log_warn "Full restore test requires interactive input - verifying script only"

    assert_success "Restore script can be invoked" \
        "${COMPOSE_CMD}" exec -T backup bash -c "echo | /backup-scripts/restore.sh 2>&1 | grep -q 'Available backups'"
}

test_files() {
    echo ""
    log_info "========================================="
    log_info "Test Suite: File Backup"
    log_info "========================================="

    # Create a backup first
    log_info "Creating backup with file..."
    ${COMPOSE_CMD} exec -T backup /backup-scripts/backup-now.sh > /dev/null 2>&1

    # Get the backup file name (just the basename)
    local backup_file
    backup_file=$(${COMPOSE_CMD} exec -T backup bash -c "ls -t /backups-local/docker-backup-sidecar-test/*.tar.gz.gpg | head -1" 2>/dev/null | tr -d '\r')

    if [ -z "$backup_file" ]; then
        log_error "No backup file found for file test"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi

    # Decrypt and extract inside the container to verify file is included
    log_info "Verifying file backup content..."
    local temp_dir="/tmp/verify-$$"

    # Create temp directory and decrypt/extract inside container
    local verify_result
    verify_result=$(${COMPOSE_CMD} exec -T backup bash -c "
        mkdir -p '$temp_dir' &&
        gpg --decrypt --batch --yes --passphrase 'test-encryption-key-change-in-production' \
            --output '$temp_dir/backup.tar.gz' '$backup_file' 2>/dev/null &&
        tar -xzf '$temp_dir/backup.tar.gz' -C '$temp_dir' 2>/dev/null &&
        if [ -f '$temp_dir/app-config' ]; then
            echo 'FILE_EXISTS'
            cat '$temp_dir/app-config'
        else
            echo 'FILE_NOT_FOUND'
        fi &&
        rm -rf '$temp_dir'
    " 2>/dev/null)

    # Check if the config file backup exists
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$verify_result" | grep -q "FILE_EXISTS"; then
        log_success "Config file was backed up successfully"
        TESTS_PASSED=$((TESTS_PASSED + 1))

        # Verify content
        assert_contains "Backed up file has correct content" \
            "$verify_result" "settings"
    else
        log_error "Config file was not found in backup"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

test_encryption() {
    echo ""
    log_info "========================================="
    log_info "Test Suite: Encryption"
    log_info "========================================="

    # Create a backup
    log_info "Creating encrypted backup..."
    ${COMPOSE_CMD} exec -T backup /backup-scripts/backup-now.sh > /dev/null 2>&1

    # Get the backup file
    local backup_file
    backup_file=$(find "${TEST_BACKUP_DIR}" -name "*.tar.gz.gpg" 2>/dev/null | head -1)

    if [ -z "$backup_file" ]; then
        log_error "No backup file found for encryption test"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi

    # Test that file is encrypted (GPG format)
    local file_type
    file_type=$(file "$backup_file" 2>/dev/null || echo "unknown")

    assert_contains "Backup file is GPG/PGP encrypted" \
        "$file_type" "PGP"

    # Test that file cannot be extracted without decryption
    assert_failure "Encrypted backup cannot be read as plain tar" \
        tar -tzf "$backup_file" 2>/dev/null
}

test_retention() {
    echo ""
    log_info "========================================="
    log_info "Test Suite: Retention Policy"
    log_info "========================================="

    # Clean existing backups first to ensure accurate count
    rm -f "${TEST_BACKUP_DIR}"/*.tar.gz.gpg

    # Count existing backups before creating new ones
    local initial_count
    initial_count=$(find "${TEST_BACKUP_DIR}" -name "*.tar.gz.gpg" 2>/dev/null | wc -l | tr -d ' ')

    # Create multiple backups
    log_info "Creating test backups..."
    for _ in 1 2 3; do
        ${COMPOSE_CMD} exec -T backup /backup-scripts/backup-now.sh > /dev/null 2>&1
        sleep 2  # Ensure different timestamps and allow backup to complete
    done

    # Wait a bit more to ensure all backups are fully written
    sleep 1

    # Count backup files now
    local backup_count
    backup_count=$(find "${TEST_BACKUP_DIR}" -name "*.tar.gz.gpg" 2>/dev/null | wc -l | tr -d ' ')

    # Calculate new backups created
    local new_backups=$((backup_count - initial_count))

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$new_backups" -eq 3 ]; then
        log_success "Created 3 new backups"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "Expected 3 new backups, got $new_backups (initial: $initial_count, final: $backup_count)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    log_info "Retention cleanup is configured for 7 days (manual testing required for old backups)"
}

test_stop_services() {
    echo ""
    log_info "========================================="
    log_info "Test Suite: Container Stop/Start"
    log_info "========================================="

    # This test verifies that BACKUP_STOP_SERVICES functionality works
    # This is critical for SQLite and other databases that require exclusive access

    # Check that app container is currently running
    local app_status
    app_status=$(${COMPOSE_CMD} ps app --format json 2>/dev/null | grep -c '"State":"running"' || echo "0")

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$app_status" -eq 1 ]; then
        log_success "App container is running before test"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "App container is not running - cannot test stop functionality"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi

    # Create a special backup container with BACKUP_STOP_SERVICES configured
    log_info "Recreating backup container with BACKUP_STOP_SERVICES=app..."

    # Stop the current backup container
    ${COMPOSE_CMD} stop backup > /dev/null 2>&1

    # Start backup container with BACKUP_STOP_SERVICES env var
    ${COMPOSE_CMD} run --rm -d \
        --name backup-stop-test \
        -e BACKUP_NAME=docker-backup-sidecar-test \
        -e BACKUP_LOCAL_PATH=/backups-local \
        -e BACKUP_ENCRYPTION_KEY=test-encryption-key-change-in-production \
        -e BACKUP_POSTGRES=postgresql://testuser:testpass123@db:5432/testdb \
        -e BACKUP_MONGODB=mongodb://testuser:testpass123@mongo:27017/testdb?authSource=admin \
        -e BACKUP_DIRS=/app/data:app-data \
        -e BACKUP_FILES=/app/config.json:app-config \
        -e BACKUP_STOP_SERVICES=app \
        -e BACKUP_STOP_WAIT=3 \
        -e BACKUP_START_WAIT=3 \
        -e BACKUP_RETENTION_DAYS=7 \
        -e TZ=America/New_York \
        backup \
        sleep 300 > /dev/null 2>&1

    # Wait a moment for container to be ready
    sleep 2

    # Verify app is still running before backup
    app_status=$(${COMPOSE_CMD} ps app --format json 2>/dev/null | grep -c '"State":"running"' || echo "0")

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$app_status" -eq 1 ]; then
        log_success "App container still running before backup"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "App container stopped unexpectedly"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Run backup which should stop and restart the app container
    log_info "Running backup with container stop enabled..."
    local backup_output
    backup_output=$(docker exec backup-stop-test /backup-scripts/backup-now.sh 2>&1)

    # Check that backup mentions stopping services
    assert_contains "Backup output shows services being stopped" \
        "$backup_output" "Stopping services: app"

    assert_contains "Backup output shows services being started" \
        "$backup_output" "Starting services: app"

    assert_contains "Backup completed successfully with stop/start" \
        "$backup_output" "Backup completed successfully"

    # Verify app container is running again after backup
    sleep 2  # Give it a moment to fully start
    app_status=$(${COMPOSE_CMD} ps app --format json 2>/dev/null | grep -c '"State":"running"' || echo "0")

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$app_status" -eq 1 ]; then
        log_success "App container restarted successfully after backup"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "App container did not restart after backup"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Parse the backup log to verify the sequence of operations
    local stop_line
    local start_line
    stop_line=$(echo "$backup_output" | grep -n "Stopping services" | cut -d: -f1)
    start_line=$(echo "$backup_output" | grep -n "Starting services" | cut -d: -f1)

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -n "$stop_line" ] && [ -n "$start_line" ] && [ "$stop_line" -lt "$start_line" ]; then
        log_success "Services stopped before starting (correct sequence)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "Service stop/start sequence incorrect (stop: $stop_line, start: $start_line)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Test with multiple services
    log_info "Testing with multiple services (app,db)..."
    backup_output=$(docker exec backup-stop-test sh -c 'BACKUP_STOP_SERVICES=app,db /backup-scripts/backup-now.sh' 2>&1)

    assert_contains "Multiple services stopped in backup output" \
        "$backup_output" "Stopping services: app,db"

    # Verify both containers are running after backup
    sleep 2
    app_status=$(${COMPOSE_CMD} ps app --format json 2>/dev/null | grep -c '"State":"running"' || echo "0")
    db_status=$(${COMPOSE_CMD} ps db --format json 2>/dev/null | grep -c '"State":"running"' || echo "0")

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$app_status" -eq 1 ] && [ "$db_status" -eq 1 ]; then
        log_success "Multiple containers restarted successfully"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_error "Not all containers restarted (app: $app_status, db: $db_status)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi

    # Cleanup - stop and remove the test backup container
    log_info "Cleaning up test backup container..."
    docker stop backup-stop-test > /dev/null 2>&1 || true
    docker rm backup-stop-test > /dev/null 2>&1 || true

    # Restart the original backup container
    ${COMPOSE_CMD} start backup > /dev/null 2>&1
    sleep 2
}

test_scripts() {
    echo ""
    log_info "========================================="
    log_info "Test Suite: Script Validation"
    log_info "========================================="

    # Test all scripts are present and executable
    local scripts=("backup-now.sh" "restore.sh" "list-backups.sh" "common.sh")

    for script in "${scripts[@]}"; do
        assert_success "Script exists: $script" \
            "${COMPOSE_CMD}" exec -T backup test -f "/backup-scripts/$script"

        if [[ "$script" != "common.sh" ]]; then
            assert_success "Script is executable: $script" \
                "${COMPOSE_CMD}" exec -T backup test -x "/backup-scripts/$script"
        fi
    done

    # Test environment variables are set
    # shellcheck disable=SC2016  # Variables should expand in container, not host
    assert_success "BACKUP_NAME is set" \
        "${COMPOSE_CMD}" exec -T backup bash -c '[ -n "$BACKUP_NAME" ]'

    # shellcheck disable=SC2016  # Variables should expand in container, not host
    assert_success "BACKUP_ENCRYPTION_KEY is set" \
        "${COMPOSE_CMD}" exec -T backup bash -c '[ -n "$BACKUP_ENCRYPTION_KEY" ]'

    # shellcheck disable=SC2016  # Variables should expand in container, not host
    assert_success "BACKUP_POSTGRES is set" \
        "${COMPOSE_CMD}" exec -T backup bash -c '[ -n "$BACKUP_POSTGRES" ]'

    # shellcheck disable=SC2016  # Variables should expand in container, not host
    assert_success "BACKUP_MONGODB is set" \
        "${COMPOSE_CMD}" exec -T backup bash -c '[ -n "$BACKUP_MONGODB" ]'
}

# ==============================================================================
# Main Test Runner
# ==============================================================================

run_all_tests() {
    log_info "========================================="
    log_info "Docker Backup Sidecar - Test Suite"
    log_info "========================================="

    setup

    test_environment
    test_scripts
    test_backup
    test_files
    test_encryption
    test_retention
    test_stop_services
    test_restore

    echo ""
    log_info "========================================="
    log_info "Test Summary"
    log_info "========================================="
    echo -e "Total Tests:  ${BLUE}${TESTS_RUN}${NC}"
    echo -e "Passed:       ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Failed:       ${RED}${TESTS_FAILED}${NC}"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        log_success "All tests passed! ✓"
        return 0
    else
        log_error "Some tests failed!"
        return 1
    fi
}

# ==============================================================================
# Script Entry Point
# ==============================================================================

main() {
    # Parse command line arguments
    case "${1:-all}" in
        all)
            run_all_tests
            exit_code=$?
            teardown
            exit $exit_code
            ;;
        environment)
            setup
            test_environment
            teardown
            ;;
        backup)
            setup
            test_backup
            teardown
            ;;
        files)
            setup
            test_files
            teardown
            ;;
        restore)
            setup
            test_restore
            teardown
            ;;
        encryption)
            setup
            test_encryption
            teardown
            ;;
        scripts)
            setup
            test_scripts
            teardown
            ;;
        stop-services)
            setup
            test_stop_services
            teardown
            ;;
        --keep-running)
            log_info "Setting up environment and keeping it running..."
            setup
            log_success "Environment is ready. Run 'docker compose -f ${COMPOSE_FILE} down -v' to clean up."
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [test-suite]"
            echo ""
            echo "Test Suites:"
            echo "  all           Run all tests (default)"
            echo "  environment   Test environment setup"
            echo "  backup        Test backup functionality"
            echo "  files         Test file backup functionality"
            echo "  restore       Test restore functionality"
            echo "  encryption    Test encryption"
            echo "  scripts       Test script validation"
            echo "  stop-services Test container stop/start during backup"
            echo ""
            echo "Options:"
            echo "  --keep-running  Set up environment without teardown"
            echo "  --help, -h      Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown test suite: $1"
            echo "Run '$0 --help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
