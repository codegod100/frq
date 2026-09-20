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

One credential and one setting live outside the repo, both one-time:

* `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET`, as rickub repository
  secrets. The registry needs none of its own -- rickub authenticates
  docker before a workflow's first step.
* The image set to **public** on rickub: its detail page, Manage,
  visibility. Private is the default, and the first push creates it
  private, so this is done once after the first green run.

The second is why there is no `registry_secret` in `container.toml`.
Modal pulls on every cold start rather than once at deploy time, so a
private image would want a long-lived rickub deploy token held as a
Modal Secret -- and what it would be guarding is `build/web`, which
the URL hands to anyone who opens it. The alternative is written down
in `container.toml` for whoever wants it.
