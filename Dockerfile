# syntax=docker/dockerfile:1
# ───────────────────────────── Base stage ─────────────────────────────
FROM public.ecr.aws/docker/library/node:lts-bookworm AS base

WORKDIR /opt/build-stage
# Enable corepack and prepare pnpm
RUN corepack enable && corepack prepare pnpm@9 --activate
RUN git clone --recurse-submodules -j8 https://github.com/AISFlow/planka-ko.git planka

# ───────────────────────────── Server build stage ─────────────────────────────
FROM base AS server-build

WORKDIR /app
COPY --from=base /opt/build-stage/planka/server/package*.json ./
RUN pnpm import && pnpm install --prod
COPY --from=base /opt/build-stage/planka/server /app

# ───────────────────────────── Client build stage ─────────────────────────────
FROM base AS client-build

WORKDIR /opt/build-stage/planka/client
RUN pnpm import && pnpm install --prod
RUN DISABLE_ESLINT_PLUGIN=true npm run build

# ───────────────────────────── Supervisord stage ────────────────────────────
FROM golang:latest AS supervisord
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone https://github.com/NavyStack/supervisord .
RUN GOOS=linux go build -tags "release osusergo netgo" -a -ldflags "-linkmode external -extldflags -static" -o /usr/local/bin/supervisord
RUN chmod +x /usr/local/bin/supervisord

# ───────────────────────────── Layer cutting stage ─────────────────────────────
FROM public.ecr.aws/docker/library/node:lts-bookworm-slim AS layer-cutter
ENV NODE_ENV=production
ENV GOSU_VERSION=1.17
ENV TINI_VERSION=v0.19.0
ENV UID=1001
ENV GID=1001
ENV TZ=Asia/Seoul

WORKDIR /app
RUN set -eux; \
    # Save list of currently installed packages for later cleanup
        savedAptMark="$(apt-mark showmanual)"; \
        apt-get update; \
        apt-get install -y --no-install-recommends ca-certificates gnupg wget; \
        rm -rf /var/lib/apt/lists/*; \
        \
    # Install gosu
        dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
        wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
        wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
        export GNUPGHOME="$(mktemp -d)"; \
        gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
        gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
        gpgconf --kill all; \
        rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
        chmod +x /usr/local/bin/gosu; \
        gosu --version; \
        gosu nobody true; \
        \
    # Install Tini
        : "${TINI_VERSION:?TINI_VERSION is not set}"; \
        dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
        echo "Downloading Tini version ${TINI_VERSION} for architecture ${dpkgArch}"; \
        wget -O /usr/local/bin/tini "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-$dpkgArch"; \
        wget -O /usr/local/bin/tini.asc "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-$dpkgArch.asc"; \
        export GNUPGHOME="$(mktemp -d)"; \
        gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys 595E85A6B1B4779EA4DAAEC70B588DFF0527A9B7; \
        gpg --batch --verify /usr/local/bin/tini.asc /usr/local/bin/tini; \
        gpgconf --kill all; \
        rm -rf "$GNUPGHOME" /usr/local/bin/tini.asc; \
        chmod +x /usr/local/bin/tini; \
        echo "Tini version: $(/usr/local/bin/tini --version)"; \
        \
    # Clean up
        apt-mark auto '.*' > /dev/null; \
        [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
        apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false

RUN set -eux; \
    groupadd --gid ${UID} planka; \
    useradd --uid ${UID} --gid ${GID} --home-dir /app planka; \
    install -d -o planka -g planka -m 700 /app && \
    apt-get update && apt-get install -y --no-install-recommends \
    supervisor nginx && \
    rm -rf /var/lib/apt/lists/* 

# Copy server app
COPY --link --chown=1001:1001 --from=server-build /app /app

# Copy built client assets
COPY --link --chown=1001:1001 --from=client-build /opt/build-stage/planka/client/build /app/public
COPY --link --chown=1001:1001 --from=client-build /opt/build-stage/planka/client/build/index.html /app/views/index.ejs

# Copy environment and entry files
COPY --link --chown=1001:1001 --from=base /opt/build-stage/planka/server/.env.sample /app/.env
COPY --link --chown=1001:1001 init /usr/local/bin/
COPY --link --from=supervisord /usr/local/bin/supervisord /usr/local/bin/supervisord
COPY --link docker/supervisord.conf /etc/supervisor/supervisord.conf
COPY --link docker/planka.conf /etc/nginx/conf.d/default.conf

# ───────────────────────────── Final stage ─────────────────────────────
FROM public.ecr.aws/docker/library/node:lts-bookworm-slim AS final
ENV NODE_ENV=production
ENV UID=1001
ENV GID=1001
ENV TZ=Asia/Seoul

WORKDIR /app

RUN set -eux; \
    groupadd --gid ${UID} planka; \
    useradd --uid ${UID} --gid ${GID} --home-dir /app planka; \
    install -d -o planka -g planka -m 700 /app && \
    apt-get update && apt-get install -y --no-install-recommends \
    nginx cron && \
    rm -rf /var/lib/apt/lists/* 

COPY --link --chown=1001:1001 --from=layer-cutter  /app /app
COPY --link --chown=1001:1001 --from=layer-cutter  /usr/local/bin/init /usr/local/bin/gosu /usr/local/bin/tini /usr/local/bin/supervisord /usr/local/bin/
COPY --link --chown=1001:1001 --from=layer-cutter  /etc/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
COPY --link --chown=1001:1001 --from=layer-cutter  /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf

# Declare mount points for persistent data
VOLUME /app/public/user-avatars
VOLUME /app/public/project-background-images
VOLUME /app/private/attachments

EXPOSE 8080/TCP
ENTRYPOINT [ "tini", "--", "init" ]
CMD ["supervisord"]
