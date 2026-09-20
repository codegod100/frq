# `web`

    FRQ_WEB_IMAGE=registry.gitlab.com/<ns>/frq/web:<sha> \
        modal deploy .modal/web/container.py

Defined by `container.toml`; `../_loader.py` is what reads it, and
its comments are the spec.

Unlike `dev`, this container builds nothing. CI builds the image --
`Dockerfile` here, two stages, the second one just the bundle and a
python -- and pushes it to the GitLab registry; this deploys that
exact tag. So the thing served is the thing that was built and
tested, and a deploy is a pull rather than a compile.

`runtime = "web"`: a Function whose [run] command listens on the one
[network] port, fronted by a stable https URL. `modal deploy` leaves
it up, and deploying again replaces it in place because the app is
named by `[container] name`.

Two credentials live outside the repo:

* `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET`, as protected CI variables.
* A Modal Secret named `gitlab-registry`, holding `REGISTRY_USERNAME`
  and `REGISTRY_PASSWORD` -- a GitLab deploy token with
  `read_registry`. Modal pulls the private image on every cold start,
  not once at deploy time, so this has to be Modal's to keep.
