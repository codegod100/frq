# `web`

    FRQ_WEB_IMAGE=registry.rickub.com/nandi/frq-web:<sha> \
        modal deploy .modal/web/container.py

Defined by `container.toml`; `../_loader.py` is what reads it, and
its comments are the spec.

Unlike `dev`, this container builds nothing. rickub builds the image
-- `Dockerfile` here, two stages, the second one just the bundle and
a python -- and pushes it to `registry.rickub.com`; this deploys that
exact tag. So the thing served is the thing that was built and
tested, and a deploy is a pull rather than a compile. The workflow is
`.rickub/workflows/web.yml`.

`runtime = "web"`: a Function whose [run] command listens on the one
[network] port, fronted by a stable https URL. `modal deploy` leaves
it up, and deploying again replaces it in place because the app is
named by `[container] name`.

Two credentials live outside the repo, both one-time setup:

* `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET`, as rickub repository
  secrets. The registry needs no secret of its own -- rickub
  authenticates docker before a workflow's first step.
* A Modal Secret named `rickub-registry`, holding `REGISTRY_USERNAME`
  and `REGISTRY_PASSWORD` for a rickub deploy token (Settings →
  Packages; pull-only, and the username is any label). Modal pulls the
  private image on every cold start rather than once at deploy time,
  so this has to be Modal's to keep and cannot be the run's own
  short-lived registry token.

Making the image public instead -- its detail page, Manage,
visibility -- removes the need for that second one entirely, at the
price of anyone being able to pull the bundle.
