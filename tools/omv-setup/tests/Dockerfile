FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash coreutils python3 grep sed && \
    rm -rf /var/lib/apt/lists/*

# Install mock OMV CLI tools
COPY tests/mock-omv-rpc /usr/local/bin/omv-rpc
COPY tests/mock-omv-salt /usr/local/bin/omv-salt
COPY tests/mock-omv-aptclean /usr/local/bin/omv-aptclean
RUN chmod +x /usr/local/bin/omv-rpc /usr/local/bin/omv-salt /usr/local/bin/omv-aptclean

# Create the data root mount point
RUN mkdir -p /mnt/data

# Copy scripts
COPY . /opt/omv-setup/
RUN chmod +x /opt/omv-setup/*.sh /opt/omv-setup/tests/*.sh

WORKDIR /opt/omv-setup
CMD ["bash", "tests/run-tests.sh"]
