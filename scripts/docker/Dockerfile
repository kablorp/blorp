FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential gcc clang make git curl m4 pkg-config bubblewrap unzip \
    libssl-dev zlib1g-dev libsqlite3-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m blorp
USER blorp
WORKDIR /home/blorp

COPY --chown=blorp:blorp compiler/blorp.opam /tmp/blorp.opam

ENV PATH="/home/blorp/.local/bin:${PATH}"
RUN mkdir -p /home/blorp/.local/bin && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi && \
    curl -fsSL "https://github.com/ocaml/opam/releases/download/2.1.5/opam-2.1.5-${ARCH}-linux" \
      -o /home/blorp/.local/bin/opam && \
    chmod +x /home/blorp/.local/bin/opam && \
    opam init --bare --disable-sandboxing -y && \
    opam switch create 4.14.0 && \
    eval $(opam env) && \
    opam install /tmp/blorp.opam --deps-only --with-test -y && \
    opam install ocamlformat -y

WORKDIR /blorp
