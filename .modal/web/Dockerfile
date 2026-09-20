# The web bundle, built once and carried as an image.
#
# Two stages, and the seam between them is the point: the first is a whole
# Flutter SDK and a Nim compiler, about a gigabyte of toolchain that exists
# only to produce `flutter/build/web`; the second is that directory and a
# python to serve it. What gets pushed to the registry, and what Modal pulls
# on every cold start, is the small half.
#
# This is the one place in the tree where a build happens inside a Dockerfile
# rather than in `just` or a Modal sandbox. It is deliberate: rickub is what
# has a registry to push to -- and docker already authenticated to it -- while
# an image is what Modal can deploy without rebuilding anything. The build itself is still `tools/toolchain.sh` -- the
# same pinned Flutter and Nim as `just build web` -- so nothing about the
# output depends on being in a container.

FROM debian:13-slim AS build

# The toolchain's own needs (git, because Flutter shells out to it against
# its SDK checkout; the unpackers; ca-certificates for curl) and Nim's one
# host dependency, a C compiler. `python3` is one too — CLAUDE.md lists it
# among what the host brings, and this image is the host here: it writes the
# OAuth client metadata below. No GTK and no CMake: the Linux desktop target
# wants those, and this is the web one.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git python3 tar unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# The same two steps as `just build web`, inlined because `just` is not here
# and is not worth an install for one call. The core is compiled to
# JavaScript and copied into `flutter/web/` rather than into the output,
# because `flutter build web` copies that directory into the bundle -- which
# is what makes the page's `<script src="frq_core.js">` resolve the same
# either way.
# Where the deployed bundle answers, for the OAuth client metadata. An
# authorization server fetches that document from the `client_id` URL and
# takes it as the authority on where a code may be sent, so it has to name
# this origin — and a Dockerfile is where the build learns what it will be.
ARG FRQ_WEB_ORIGIN=https://codegod100--frq-web-serve.modal.run
RUN python3 tools/client-metadata.py "$FRQ_WEB_ORIGIN" \
      > flutter/web/client-metadata.json

RUN tools/toolchain.sh exec -- bash -euo pipefail -c '\
      mkdir -p /src/build/web && cd /src/nim && \
      nim js -d:release --hints:off --path:src --path:web \
          --out:/src/build/web/frq_core.js web/frq_web.nim && \
      cp /src/build/web/frq_core.js /src/flutter/web/frq_core.js && \
      cd /src/flutter && flutter pub get && flutter build web'

# python:*-slim and not debian:*-slim, for two reasons that happen to agree:
# Modal runs its own client inside the container, so the image needs a Python
# it can use, and the server is `http.server` -- the same one `just run web`
# starts on localhost, so what is served here is served the same way there.
FROM python:3.13-slim

COPY --from=build /src/flutter/build/web /srv/web

EXPOSE 8000
COPY --from=build /src/tools/webserve.py /srv/webserve.py
CMD ["python3", "/srv/webserve.py", "8000", "/srv/web"]
