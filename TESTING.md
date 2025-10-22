# Testing

Comprehensive automated testing for docker-backup-sidecar.

## Quick Start

```bash
# Run all tests
./test.sh
just test

# Quick smoke tests
just test-quick

# Specific test suites
just test-backup    # Backup functionality
just test-env       # Environment setup
```

## What Gets Tested

- **Environment** - Container startup, database initialization, sample data
- **Backup** - PostgreSQL, file backups, encryption, file creation
- **Scripts** - All scripts present, executable, proper permissions
- **Security** - GPG encryption verification
- **Retention** - Multiple backup creation and cleanup

## Available Commands

### Test Commands

```bash
./test.sh all           # Run all tests
./test.sh environment   # Test environment only
./test.sh backup        # Test backup only
./test.sh scripts       # Test scripts only
./test.sh --keep-running # Start env without teardown

just test              # Run all tests
just test-quick        # Quick tests only
just test-backup       # Backup tests only
```

### Manual Operations

```bash
just up       # Start test environment
just backup   # Run manual backup
just list     # List backups
just logs     # View backup logs
just down     # Stop environment
just clean    # Full cleanup with backups
```

## Example Output

```text
[INFO] Docker Backup Sidecar - Test Suite
[✓] Backup completes successfully
[✓] PostgreSQL database is backed up
[✓] Backup is encrypted
[✓] Backup file created

Total Tests:  25
Passed:       25
Failed:       0
[✓] All tests passed!
```

## Development Workflow

1. Before changes: `just test`
2. Make your changes
3. After changes: `just test`
4. If tests fail: `just up` to debug
5. Commit with confidence!

## Test Environment

Uses `docker-compose.example.yml` with:

- PostgreSQL 16 with sample data
- Alpine app writing log files
- Backup sidecar configured for both

## Adding Tests

Add test function in `test.sh`:

```bash
test_my_feature() {
    log_info "Test Suite: My Feature"
    
    assert_success "Feature works" \
        ${COMPOSE_CMD} exec backup /backup-scripts/my-script.sh
}
```

Add to `run_all_tests()` and CLI options in `main()`.

## Assertion Functions

```bash
assert_success "description" command      # Command succeeds
assert_failure "description" command      # Command fails
assert_contains "desc" "$text" "needle"   # Contains substring
assert_file_exists "description" "path"   # File exists
wait_for "description" timeout command    # Wait with timeout
```

## Troubleshooting

**Tests hang:** Check Docker is running, try `just clean`  
**Permission errors:** `chmod +x test.sh init-test-postgres.sh`  
**Test failures:** Use `just up` and `just logs` to debug

## Manual Testing Required

Some features need manual testing:

- Full restore workflow (interactive)
- S3/cloud backups (requires credentials)
- Scheduled execution (requires time)
- Webhook notifications (requires endpoint)

## Best Practices

- Run tests before committing
- Use `--keep-running` for debugging
- Update tests when adding features

**Run `just test` after every change!**
