FROM alpine:3

# Install required tools
RUN apk add --no-cache \
    bash \
    curl \
    gnupg \
    docker-cli \
    aws-cli \
    postgresql15-client \
    postgresql16-client \
    postgresql17-client \
    mongodb-tools \
    sqlite \
    tar \
    gzip \
    dcron \
    findutils \
    tzdata

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

# Create scripts and backup directories
RUN mkdir -p /backup-scripts /backups /var/log



# Copy common scripts
COPY scripts/* /backup-scripts/

# Make scripts executable
RUN chmod +x /backup-scripts/*.sh

# Set working directory
WORKDIR /backups

# Use entrypoint script to handle cron configuration
ENTRYPOINT ["/backup-scripts/entrypoint.sh"]
