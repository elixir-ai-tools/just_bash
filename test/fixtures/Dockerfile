FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      coreutils \
      findutils \
      gawk \
      grep \
      jq \
      sed \
      && rm -rf /var/lib/apt/lists/*

WORKDIR /work

# The runner script is mounted at runtime
ENTRYPOINT ["bash"]
