FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential gcc clang make git curl pkg-config bubblewrap unzip \
    libssl-dev zlib1g-dev libsqlite3-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m blorp
# Mount point for scripts/docker-gate's named volume of analysis stamps. A new
# named volume copies this directory's ownership, so the gate user can write it.
RUN mkdir /blorp-quality-cache && chown blorp:blorp /blorp-quality-cache
USER blorp

WORKDIR /blorp
