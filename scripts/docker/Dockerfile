FROM ubuntu:24.04
ARG OCAML_COMPILER=ocaml-base-compiler.4.14.2
ARG OPAM_VERSION=2.1.5
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential gcc clang make git curl m4 pkg-config bubblewrap unzip \
    libssl-dev zlib1g-dev libsqlite3-dev libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m blorp
USER blorp
WORKDIR /home/blorp

COPY --chown=blorp:blorp compiler/blorp.opam compiler/blorp.opam.locked /tmp/

ENV PATH="/home/blorp/.local/bin:${PATH}"
RUN mkdir -p /home/blorp/.local/bin && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi && \
    curl -fsSL "https://github.com/ocaml/opam/releases/download/${OPAM_VERSION}/opam-${OPAM_VERSION}-${ARCH}-linux" \
      -o /home/blorp/.local/bin/opam && \
    chmod +x /home/blorp/.local/bin/opam && \
    opam init --bare --disable-sandboxing -y && \
    opam switch create "${OCAML_COMPILER}" && \
    eval $(opam env) && \
    opam install /tmp/blorp.opam --deps-only --with-test --locked -y

WORKDIR /blorp
