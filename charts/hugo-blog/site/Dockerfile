# the following version can be overridden at image build time with --build-arg
# https://github.com/gohugoio/hugo
# renovate: datasource=github-releases depName=gohugoio/hugo
ARG HUGO_VERSION=0.148.2

# remove/comment the following line completely to compile vanilla Hugo:
ARG HUGO_BUILD_TAGS=extended

# ---

# Hugo >= v0.81.0 requires Go 1.16+ to build
# https://hub.docker.com/_/golang/
FROM golang:1.25-alpine AS build

# renew global args from above
# https://docs.docker.com/engine/reference/builder/#scope
ARG HUGO_VERSION
ARG HUGO_BUILD_TAGS

ARG CGO=1
ENV CGO_ENABLED=${CGO}
ENV GOOS=linux
ENV GO111MODULE=on

WORKDIR /go/src/github.com/gohugoio/hugo

# gcc/g++ are required to build SASS libraries for extended version
RUN apk upgrade --update --no-cache && apk add --update --no-cache \
      gcc \
      g++ \
      musl-dev \
      git

# clone source from Git repo:
RUN git clone \
      --branch "v${HUGO_VERSION}" \
      --single-branch \
      --depth 1 \
      https://github.com/gohugoio/hugo.git ./

# https://github.com/gohugoio/hugo/commit/241481931f5f5f2803cd4be519936b26d8648dfd
RUN go build -v -ldflags "-X github.com/gohugoio/hugo/common/hugo.vendorInfo=docker" -tags "$HUGO_BUILD_TAGS" && \
    mv ./hugo /go/bin/hugo

# fix potential stack size problems on Alpine
# https://github.com/microsoft/vscode-dev-containers/blob/fb63f7e016877e13535d4116b458d8f28012e87f/containers/hugo/.devcontainer/Dockerfile#L19
RUN go install github.com/yaegashi/muslstack@latest && \
    muslstack -s 0x800000 /go/bin/hugo

# ---

# https://hub.docker.com/_/alpine
FROM alpine:3.22

# renew global args from above & pin any dependency versions
ARG HUGO_VERSION
# https://github.com/jgm/pandoc/releases
# renovate: datasource=github-releases depName=jgm/pandoc
ARG PANDOC_VERSION=3.6.4
# https://github.com/sass/dart-sass-embedded/releases
# renovate: datasource=github-releases depName=sass/dart-sass-embedded
ARG DART_SASS_VERSION=1.62.1

LABEL version="${HUGO_VERSION}"
LABEL repository="https://github.com/bocan/odin-hugo"
LABEL homepage="https://chris.funderburg.me/"
LABEL maintainer="Chris Funderburg <chris@funderburg.me>"

# https://docs.github.com/en/free-pro-team@latest/packages/managing-container-images-with-github-container-registry/connecting-a-repository-to-a-container-image#connecting-a-repository-to-a-container-image-on-the-command-line
LABEL org.opencontainers.image.source="https://github.com/bocan/odin-hugo"

# bring over patched binary from build stage
COPY --from=build /go/bin/hugo /usr/bin/hugo

# this step is intentionally a bit of a mess to minimize the number of layers in the final image
RUN set -euo pipefail && \
    if [ "$(uname -m)" = "x86_64" ]; then \
      ARCH="amd64"; \
    elif [ "$(uname -m)" = "aarch64" ]; then \
      ARCH="arm64"; \
    else \
      echo "Unknown build architecture, quitting." && exit 2; \
    fi && \
    # alpine packages
    # libc6-compat & libstdc++ are required for extended SASS libraries
    # ca-certificates are required to fetch outside resources (like Twitter oEmbeds)
    apk upgrade --update --no-cache && apk add --update --no-cache \
      ca-certificates \
      tzdata \
      git \
      nodejs \
      npm \
      go \
      python3 \
      py3-pip \
      ruby \
      libc6-compat \
      libstdc++ && \
    update-ca-certificates && \
    # npm packages
    npm install --global --production \
      yarn \
      postcss \
      postcss-cli \
      autoprefixer \
      @babel/core \
      @babel/cli && \
    npm cache clean --force && \
    # ruby gems
    gem install asciidoctor && \
    # python packages
    python3 -m pip install --no-cache-dir --break-system-packages  --upgrade Pygments==2.* docutils rst2html && \
    # manually fetch pandoc binary
    wget -O pandoc.tar.gz https://github.com/jgm/pandoc/releases/download/${PANDOC_VERSION}/pandoc-${PANDOC_VERSION}-linux-${ARCH}.tar.gz && \
    tar xf pandoc.tar.gz && \
    mv ./pandoc-${PANDOC_VERSION}/bin/pandoc /usr/bin/ && \
    chmod +x /usr/bin/pandoc && \
    rm -rf pandoc.tar.gz pandoc-${PANDOC_VERSION} && \
    # manually fetch Dart SASS binary (on x64 only)
    if [ "$ARCH" = "amd64" ]; then \
      wget -O sass-embedded.tar.gz https://github.com/sass/dart-sass/releases/download/1.91.0/dart-sass-1.91.0-linux-x64.tar.gz && \
      tar xf sass-embedded.tar.gz && \
      mv ./dart-sass/* /usr/bin/ && \
      chmod a+rwx /usr/bin/sass && \
      rm -rf sass-embedded.tar.gz dart-sass; \
    fi && \
    # clean up some junk
    rm -rf /tmp/* /var/tmp/* /var/cache/apk/* && \
    # tell git to trust /src
    git config --global --add safe.directory /src && \
    # make super duper sure that everything went OK, exit otherwise
    hugo env && \
    go version && \
    node --version && \
    npm --version && \
    yarn --version && \
    postcss --version && \
    autoprefixer --version && \
    babel --version && \
    pygmentize -V && \
    asciidoctor --version && \
    pandoc --version && \
    rst2html --version

# add site source as volume
WORKDIR /src
COPY . .
# expose live-refresh server on default port
EXPOSE 1313
# RUN hugo --gc --minify
RUN ls /src
RUN echo $PWD

CMD ["hugo", "server", "--buildDrafts", "--buildFuture", "--bind", "0.0.0.0", "--baseURL", "lz.dev.kubernative.io", "--appendPort=false"]
