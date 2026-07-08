# Headless UltraWork workspace container for Fly.io.
# This is a containerized variant of RegicideOSArch, not the full VM OS.

FROM archlinux:base@sha256:9e9da3122b537ad94f22c8c6f89c1e3f253f3a1e22944364a061c75a041705da

ENV MAKEFLAGS=-j4
ENV LC_ALL=C.UTF-8
ENV LANG=C.UTF-8

# Copy shared package lists before installing so changes are cache-friendly.
COPY build-system/packages /tmp/regicide-packages

# Initialize pacman keyring and install workspace packages.
RUN pacman-key --init && \
    pacman-key --populate archlinux && \
    pacman -Sy --noconfirm archlinux-keyring && \
    pacman -S --needed --noconfirm \
      base \
      base-devel \
      openssh \
      git \
      tmux \
      nodejs \
      npm \
      podman \
      distrobox \
      sudo \
      curl \
      ca-certificates \
      util-linux \
      $(cat /tmp/regicide-packages/vm.txt | grep -v '^#' | grep -v '^$' | tr '\n' ' ') \
    && \
    rm -rf /var/cache/pacman/pkg/* /tmp/regicide-packages

# Copy and run post-install configuration.
COPY build-system/arch/container/post-install.sh /tmp/post-install.sh
RUN bash /tmp/post-install.sh && rm /tmp/post-install.sh

# Copy the PID 1 init script.
COPY build-system/arch/container/init /opt/ultrawork/sbin/init
RUN chmod +x /opt/ultrawork/sbin/init

VOLUME ["/data"]
EXPOSE 22 8080

ENTRYPOINT ["/opt/ultrawork/sbin/init"]
