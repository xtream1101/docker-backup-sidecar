# Test Suite

This directory contains all test-related files for docker-backup-sidecar.

## Files

- **`test.sh`** - Main test suite script with all automated tests
- **`docker-compose.example.yml`** - Test environment configuration with PostgreSQL, MongoDB, and sample app
- **`init-test-postgres.sql`** - PostgreSQL database initialization script (creates sample data)
- **`init-test-mongo.js`** - MongoDB database initialization script (creates sample data)
- **`test-config.json`** - Sample configuration file for testing file backups

## Running Tests

From the project root:

```bash
# Run all tests
just test

# Run quick tests (environment + scripts only)
just test-quick

# Run specific test suites
just test-env          # Environment tests
just test-backup       # Backup tests
just test-restore      # Restore tests
```

Or run the test script directly:

```bash
./tests/test.sh all           # All tests
./tests/test.sh environment   # Environment only
./tests/test.sh backup        # Backup only
```

## Test Environment

The test environment includes:

- **PostgreSQL 16** - with 3 sample users
- **MongoDB 8** - with 3 sample users  
- **Alpine app** - writing logs to `/app/data`
- **Backup sidecar** - configured to backup all sources

All services are configured to work together without requiring external configuration files.

## Documentation

See [TESTING.md](../TESTING.md) in the project root for complete testing documentation.
