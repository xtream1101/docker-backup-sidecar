# Stage 1: Extract PostgreSQL client binaries
FROM alpine:3 AS postgres-binaries

# Install all PostgreSQL client versions
RUN apk add --no-cache \
    postgresql15-client \
    postgresql16-client \
    postgresql17-client

# Stage 2: Final image
FROM alpine:3

# Install required tools (excluding PostgreSQL clients)
RUN apk add --no-cache \
    bash \
    curl \
    gnupg \
    docker-cli \
    aws-cli \
    mongodb-tools \
    sqlite \
    tar \
    gzip \
    dcron \
    findutils \
    tzdata \
    # PostgreSQL dependencies needed to run the binaries
    libpq \
    lz4-libs \
    zstd-libs \
    && mkdir -p /backup-scripts /backups /var/log

# Copy PostgreSQL binaries from the builder stage
COPY --from=postgres-binaries /usr/libexec/postgresql15/ /usr/libexec/postgresql15/
COPY --from=postgres-binaries /usr/libexec/postgresql16/ /usr/libexec/postgresql16/
COPY --from=postgres-binaries /usr/libexec/postgresql17/ /usr/libexec/postgresql17/

# Set up PostgreSQL client symlinks for all versions
# By default, use pg16 clients (most compatible middle ground)
RUN ln -sf /usr/libexec/postgresql15/pg_dump /usr/local/bin/pg_dump15 && \
    ln -sf /usr/libexec/postgresql15/pg_restore /usr/local/bin/pg_restore15 && \
    ln -sf /usr/libexec/postgresql15/psql /usr/local/bin/psql15 && \
    ln -sf /usr/libexec/postgresql16/pg_dump /usr/local/bin/pg_dump16 && \
    ln -sf /usr/libexec/postgresql16/pg_restore /usr/local/bin/pg_restore16 && \
    ln -sf /usr/libexec/postgresql16/psql /usr/local/bin/psql16 && \
    ln -sf /usr/libexec/postgresql17/pg_dump /usr/local/bin/pg_dump17 && \
    ln -sf /usr/libexec/postgresql17/pg_restore /usr/local/bin/pg_restore17 && \
    ln -sf /usr/libexec/postgresql17/psql /usr/local/bin/psql17 && \
    ln -sf /usr/local/bin/pg_dump16 /usr/local/bin/pg_dump && \
    ln -sf /usr/local/bin/pg_restore16 /usr/local/bin/pg_restore && \
    ln -sf /usr/local/bin/psql16 /usr/local/bin/psql

# Copy common scripts
COPY scripts/* /backup-scripts/

# Make scripts executable
RUN chmod +x /backup-scripts/*.sh

# Set working directory
WORKDIR /backups

# Use entrypoint script to handle cron configuration
ENTRYPOINT ["/backup-scripts/entrypoint.sh"]
