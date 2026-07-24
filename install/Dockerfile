FROM steamcmd/steamcmd:ubuntu-22

ARG PALWORLD_PROJECT_DIR=/opt/palworld-project

LABEL io.palworld.image="palworld-dedicated-server" \
    io.palworld.runtime-layout="policy-bind-v1+update-lock-v1" \
    io.palworld.project-dir="${PALWORLD_PROJECT_DIR}"

USER root

ARG PALWORLD_UID=1000
ARG PALWORLD_GID=1000

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        libcurl4 \
        python3 \
        tini \
        tzdata \
        xdg-user-dirs \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${PALWORLD_GID}" palworld \
    && useradd --uid "${PALWORLD_UID}" --gid "${PALWORLD_GID}" \
        --create-home --home-dir /home/palworld --shell /bin/bash palworld

ENV DATA_DIR=/palworld \
    HOME=/home/palworld \
    USER=palworld \
    PYTHONPATH=/opt/palworld \
    PYTHONUNBUFFERED=1

RUN mkdir -p /opt/palworld /palworld/server /home/palworld/.steam \
    && chown -R "${PALWORLD_UID}:${PALWORLD_GID}" /home/palworld /palworld

# The container only needs runtime code. Host-side setup, diagnostics, and
# instance generation stay in the temporary Linux installer payload.
COPY scripts/common.py scripts/management_api.py scripts/manager.py scripts/palctl.py scripts/policy.py scripts/resource_metrics.py scripts/world_backup.py /opt/palworld/

RUN chmod +x /opt/palworld/manager.py /opt/palworld/palctl.py \
    && ln -s /opt/palworld/palctl.py /usr/local/bin/palctl

USER palworld:palworld

RUN steamcmd +quit

WORKDIR /palworld/server

EXPOSE 8211/udp

ENTRYPOINT ["/usr/bin/tini", "--", "python3", "/opt/palworld/manager.py"]
