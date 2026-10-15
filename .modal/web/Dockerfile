# The web bundle, built once and carried as an image.
#
# Two stages, and the seam between them is the point: the first is a Nim
# compiler and a C toolchain, which exist only to produce `build/web`; the
# second is that directory and a python to serve it. What gets pushed to the registry, and what Modal pulls
# on every cold start, is the small half.
#
# This is the one place in the tree where a build happens inside a Dockerfile
# rather than in `just` or a Modal sandbox. It is deliberate: GitHub Actions is what
# has a registry to push to -- and docker already authenticated to it -- while
# an image is what Modal can deploy without rebuilding anything. The build itself is still `tools/toolchain.sh` -- the
# same pinned Nim as `just build web` -- so nothing about the output depends
# on being in a container.

FROM debian:13-slim AS build

# The toolchain's own needs (the unpacker; ca-certificates for curl) and
# Nim's one host dependency, a C compiler. `python3` is one too — CLAUDE.md
# lists it among what the host brings, and this image is the host here. No
# GTK: the Linux desktop target wants those, and this is the web one.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl python3 tar xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

# The same steps as `just build web`, inlined because `just` is not here and
# is not worth an install for one call. Inlined means duplicated, so the
# flags have to be kept in step with that recipe: the page in web/ copied
# beside `frq.js`, which is the core, its renderer and nimkit's web backend
# compiled by `nim js`.
# The OAuth client metadata is not in the bundle: `tools/webserve.py` answers
# `/client-metadata.json` from the host each request arrives at, because the
# `client_id` in it has to equal that URL and the build cannot know it.
RUN rm -rf build/web && mkdir -p build/web && cp -r web/. build/web/

RUN tools/toolchain.sh exec -- bash -euo pipefail -c '\
      cd /src/nim && \
      nim js -d:release --hints:off --path:../src --path:. \
          --out:/src/build/web/frq.js web/frq_app.nim'

# python:*-slim and not debian:*-slim, for two reasons that happen to agree:
# Modal runs its own client inside the container, so the image needs a Python
# it can use, and the server is `tools/webserve.py` -- the same one
# `just run web` starts on localhost, so what is served here is served the
# same way there.
FROM python:3.13-slim

COPY --from=build /src/build/web /srv/web

EXPOSE 8000
COPY --from=build /src/tools/webserve.py /srv/webserve.py
CMD ["python3", "/srv/webserve.py", "8000", "/srv/web"]
