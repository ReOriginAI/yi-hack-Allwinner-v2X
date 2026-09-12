ARG VARIANT="debian-11"
FROM mcr.microsoft.com/vscode/devcontainers/base:0-${VARIANT}

RUN export DEBIAN_FRONTEND=noninteractive               && \
    apt-get update                                      && \
    apt-get -y install --no-install-recommends             \
      git wget unzip build-essential libtool bison         \
      bisonc++ libbison-dev autoconf autotools-dev         \
      automake libssl-dev zlib1g-dev libzzip-dev           \
      flex libfl-dev yui-compressor closure-compiler       \
      optipng jpegoptim libtidy5deb1 node-less sassc       \
      sass-spec libhtml-tidy-perl libxml2-utils rsync cmake \
      qemu-user-static pkg-config curl bzip2 file

ARG GO_VERSION=1.24.0
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz -o /tmp/go.tar.gz && \
    rm -rf /usr/local/go && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    rm -f /tmp/go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"

# Download toolchain
RUN git clone https://github.com/lindenis-org/lindenis-v536-prebuilt                                              && \
    mkdir -p /opt/yi/toolchain-sunxi-musl                                                                         && \
    cp -r lindenis-v536-prebuilt/gcc/linux-x86/arm/toolchain-sunxi-musl/toolchain /opt/yi/toolchain-sunxi-musl/

