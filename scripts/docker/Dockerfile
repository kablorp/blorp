FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential gcc clang make git curl pkg-config bubblewrap unzip \
    libssl-dev zlib1g-dev libsqlite3-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m blorp
USER blorp

WORKDIR /blorp
