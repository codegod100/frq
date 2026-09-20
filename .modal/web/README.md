# `web`

    FRQ_WEB_IMAGE=registry.rickub.com/nandi/frq-web:<sha> \
        modal deploy .modal/web/app.py

Plain Modal, in `app.py`. There is no `container.toml` here and no
`_loader.py` behind it: `dev` has a spec because it is a sandbox
with a volume, a toolchain and a command that changes, and this is
four constants and a `Popen`.

Unlike `dev`, this container builds nothing. rickub builds the image
-- `Dockerfile` here, two stages, the second one just the bundle and
a python -- and pushes it to `registry.rickub.com`; this deploys that
exact tag. So the thing served is the thing that was built and
tested, and a deploy is a pull rather than a compile. The workflow is
`.rickub/workflows/web.yml`.

`@modal.web_server`: a Function whose command listens on a port,
fronted by a stable https URL. Modal waits for the port to accept a
connection and then proxies to it, which is why the command is a
`Popen` that keeps running rather than a `run` that finishes.
`modal deploy` leaves it up, and deploying again replaces it in
place because `modal.App("frq-web")` names it.

One credential and one setting live outside the repo, both one-time:

* `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET`, as rickub repository
  secrets. The registry needs none of its own -- rickub authenticates
  docker before a workflow's first step.
* The image set to **public** on rickub: its detail page, Manage,
  visibility. Private is the default, and the first push creates it
  private, so this is done once after the first green run.

The second is why `from_registry` is called without a `secret`.
Modal pulls on every cold start rather than once at deploy time, so a
private image would want a long-lived rickub deploy token held as a
Modal Secret -- and what it would be guarding is `build/web`, which
the URL hands to anyone who opens it. The alternative is written down
in `app.py` for whoever wants it.
