"""Turn a `container.toml` into a `modal.Image` and a `modal.App`.

Every container -- under `containers/` here, `.modal/` in a repo that merely
builds itself on Modal -- is a directory with a `container.toml` and
a stub `container.py`. The keys are documented by the comments below, which
is the whole of the spec. Nothing here is Modal-specific configuration in its
own right -- each
spec key maps onto a documented Modal argument, and the mapping is meant to
stay boring enough to read straight through.
"""

import os
import subprocess
import tomllib

import modal


class SpecError(Exception):
    """The container.toml says something that cannot be built."""


def _running_in_modal() -> bool:
    """True inside a Modal container, false on the machine that launched it."""
    return bool(os.environ.get("MODAL_TASK_ID"))


class Container:
    """One container: its spec, its image, its app, and how to run it."""

    def __init__(self, spec: dict, directory: str):
        self.is_remote = _running_in_modal()
        self.dir = directory
        self.spec = spec
        self.name = self._require("container", "name")
        self.description = spec.get("container", {}).get("description", "")

        run = spec.get("run", {})
        self.workdir = run.get("workdir", "/app")
        self.command = run.get("command", "")
        self.env = dict(run.get("env", {}))

        # "function" (the default) or "sandbox". Sandboxes can run on a real
        # VM, which Functions cannot -- see ../README.md.
        self.runtime = spec.get("container", {}).get("runtime", "function")

        # name -> mount path. Modal Volumes, mounted while the container runs
        # and NOT while its image is built: a volume mount is not part of the
        # resulting image, so anything written to one during a build step is
        # gone by the time the container starts. Persist across runs is the
        # whole point -- a toolchain too big to fetch every run, a build
        # tree an incremental compile reuses, a dataset too big to bake in.
        self.volume_spec = dict(spec.get("volumes", {}))

        # Ports to tunnel out of a Sandbox, from [network] ports. Encrypted,
        # which is Modal's own word for "the tunnel terminates TLS and speaks
        # plain HTTP to your process" -- so the thing listening inside is an
        # ordinary http.server and not something holding a certificate.
        #
        # Sandbox-only: a Function has no long-lived process to tunnel into,
        # and `modal run` on one would hand back a URL for a container that
        # has already exited.
        self.ports = [int(p) for p in spec.get("network", {}).get("ports", [])]

        # Modal re-imports this module inside the container, so everything
        # below runs twice: once here, once out there. Out there the local
        # tree does not exist -- no repo to copy from -- and
        # the image is already built, so validating and rebuilding it would
        # only fail. The App still has to exist for the decorators to bind.
        if self.is_remote:
            self.image = None
            self.app = modal.App(self.name)
        else:
            self._validate()
            self.image = self._build_image()
            self.app = modal.App(self.name, image=self.image)

    # -- spec reading ----------------------------------------------------

    @classmethod
    def from_toml(cls, container_py: str) -> "Container":
        """Load the container.toml sitting next to the given container.py."""
        directory = os.path.dirname(os.path.abspath(container_py))
        path = os.path.join(directory, "container.toml")
        if not os.path.exists(path):
            raise SpecError(f"no container.toml in {directory}")
        with open(path, "rb") as f:
            return cls(tomllib.load(f), directory)

    def _require(self, table: str, key: str):
        try:
            return self.spec[table][key]
        except KeyError:
            raise SpecError(f"container.toml needs [{table}] {key}") from None

    def _validate(self):
        c = self.spec.get("container", {})
        if self.runtime not in ("function", "sandbox"):
            raise SpecError(
                f'[container] runtime must be "function" or "sandbox",'
                f" not {self.runtime!r}"
            )
        if bool(c.get("base")) == bool(c.get("registry")):
            raise SpecError("set exactly one of [container] base or registry")
        if self.ports and self.runtime != "sandbox":
            raise SpecError(
                "[network] ports needs [container] runtime = \"sandbox\" --"
                " a Function has no process to tunnel into"
            )
        for name, mount in self.volume_spec.items():
            if not isinstance(mount, str) or not mount.startswith("/"):
                raise SpecError(
                    f"[volumes] {name} must be an absolute path, not {mount!r}"
                )
            # Mounting over one of these hides what the image already has
            # there: an empty volume would shadow what the image's own build
            # put in its place.
            if mount.rstrip("/") in ("", "/usr", "/etc", "/bin", "/lib"):
                raise SpecError(
                    f"[volumes] {name} may not mount over {mount} --"
                    " it would hide what the image has there"
                )
            if mount.rstrip("/") == self.workdir.rstrip("/"):
                raise SpecError(
                    f"[volumes] {name} may not mount over the workdir"
                    f" ({mount}) -- [build] include copies land there"
                )

    # -- image -----------------------------------------------------------

    def _build_image(self) -> modal.Image:
        c = self.spec["container"]
        build = self.spec.get("build", {})

        if c.get("base"):
            image = modal.Image.from_name(c["base"])
        else:
            image = modal.Image.from_registry(c["registry"])

        # copy=True throughout: later run_commands need these files present.
        # `context` is what include paths are relative to, and it may sit above
        # the container directory -- a container that builds the repo it lives
        # in sets context = "../..", so include = ["."] means the whole repo.
        context = os.path.normpath(os.path.join(self.dir, build.get("context", ".")))

        # Image building and program building, kept apart.
        #
        # `[build] commands` run AFTER the source copy, so any edit anywhere
        # in the tree invalidates them. `warm` + `setup` are the same step
        # moved in front of the source: `warm` names only the files the step
        # actually reads, and `setup` runs against those alone, so editing
        # `flutter/src` invalidates nothing above the final copy. A container
        # whose setup is an `apt-get` needs no `warm` at all -- it reads
        # nothing out of the tree, so nothing in the tree can invalidate it.
        for rel in build.get("warm", []):
            src = os.path.normpath(os.path.join(context, rel))
            dest = f"{self.workdir}/{rel}"
            if os.path.isdir(src):
                image = image.add_local_dir(src, dest, copy=True)
            else:
                image = image.add_local_file(src, dest, copy=True)
        if setup := build.get("setup", []):
            image = image.run_commands(*setup, volumes=self.volumes)
        # `ignore` is what keeps a build tree out of the image. A checkout that
        # has been built in locally carries its output -- flutter/build and the
        # caches beside it were 395MB of a 441MB repo -- and all of it would be
        # uploaded on every start only to be thrown away, since the container
        # builds into a volume of its own. Patterns are relative to the copied
        # directory, as in .dockerignore.
        ignore = list(build.get("ignore", []))
        for rel in build.get("include", ["."]):
            src = os.path.normpath(os.path.join(context, rel))
            dest = self.workdir if rel == "." else f"{self.workdir}/{rel}"
            if os.path.isdir(src):
                image = image.add_local_dir(src, dest, copy=True, ignore=ignore)
            else:
                image = image.add_local_file(src, dest, copy=True)

        # A repo copied in brings its `.git` along, and in a worktree that is
        # a *file* holding `gitdir: <path on the machine that copied it>` --
        # which points at nothing out here, so any tool that follows it fails
        # in a way that has nothing to do with what it was asked to do.
        # Nothing in a container wants the git metadata, so it goes.
        image = image.run_commands(f"rm -rf {self.workdir}/.git")

        if commands := build.get("commands", []):
            # Volumes mounted for the build too, not just the run, so a step
            # can read a cache the last run filled. The mount is not part of
            # the resulting image; only what the step writes outside it is.
            image = image.run_commands(*commands, volumes=self.volumes)

        # container.py does `from _loader import Container`, and Modal mounts
        # the entrypoint file alone -- so without this the import that works
        # locally fails in the container. copy=False adds it at startup rather
        # than baking a layer, so it invalidates nothing above it, and it must
        # therefore come after every build step.
        image = image.add_local_python_source("_loader")
        # ...and container.py reads its spec at import time, so the spec has to
        # be there too. Modal re-imports the entrypoint at /root, which is the
        # one directory that gets none of the workdir copies above.
        image = image.add_local_file(
            os.path.join(self.dir, "container.toml"), "/root/container.toml"
        )

        return image

    # -- volumes ---------------------------------------------------------

    @property
    def volumes(self) -> dict:
        """{mount path: Volume}, as both Sandbox.create and @app.function want.

        `from_name` is lazy, so this is safe to evaluate on the re-import
        inside the container as well as out here. create_if_missing means a
        spec naming a volume that does not exist yet makes it rather than
        failing -- the first run of a cache is the one that fills it.
        """
        return {
            mount: modal.Volume.from_name(name, create_if_missing=True)
            for name, mount in self.volume_spec.items()
        }

    # -- function --------------------------------------------------------

    @property
    def function_kwargs(self) -> dict:
        """Everything `@app.function` should be given, from [resources]."""
        r = self.spec.get("resources", {})
        kwargs: dict = {"timeout": int(r.get("timeout", 900))}
        if r.get("cpu"):
            kwargs["cpu"] = float(r["cpu"])
        if r.get("memory"):
            kwargs["memory"] = int(r["memory"])
        if r.get("gpu"):
            kwargs["gpu"] = r["gpu"]
        # Deliberately NOT self.experimental_options: that fills in the
        # sandbox default, and vm_runtime on a Function is refused by the
        # server. A sandbox container's @app.function is vestigial anyway.
        if self.runtime == "function":
            if experimental := dict(self.spec.get("experimental", {})):
                kwargs["experimental_options"] = experimental
        if volumes := self.volumes:
            kwargs["volumes"] = volumes
        return kwargs

    @property
    def experimental_options(self) -> dict:
        """Experimental options, with the sandbox default filled in.

        `vm_runtime` is Sandbox-only: the server rejects it on a Function
        outright. So it is defaulted on for sandboxes and never for functions,
        and an explicit [experimental] table always wins.
        """
        explicit = dict(self.spec.get("experimental", {}))
        if explicit:
            return explicit
        if self.runtime == "sandbox":
            return {"vm_runtime": True}
        return {}

    @property
    def sandbox_kwargs(self) -> dict:
        """Everything `Sandbox.create` should be given, from [resources]."""
        r = self.spec.get("resources", {})
        kwargs: dict = {"timeout": int(r.get("timeout", 900))}
        if r.get("cpu"):
            kwargs["cpu"] = float(r["cpu"])
        if r.get("memory"):
            # A VM sandbox gets exactly this much and cannot grow into more.
            kwargs["memory"] = int(r["memory"])
        if opts := self.experimental_options:
            kwargs["experimental_options"] = dict(opts)
        if volumes := self.volumes:
            kwargs["volumes"] = volumes
        if self.ports:
            kwargs["encrypted_ports"] = list(self.ports)
        return kwargs

    def shell_command(self, override: str = "") -> str:
        """The full shell line the container runs."""
        command = override or self.command
        if not command:
            raise SpecError("container.toml has no [run] command")
        return f"cd {self.workdir} && {command}"

    def run_sandbox(self, override: str = "") -> str:
        """Run one command in a Sandbox that dies when the command does.

        The command IS the sandbox's process, rather than something exec'd
        into a `sleep infinity` box that then has to be torn down. There is no
        idle window to pay for and nothing to leak if this script is killed;
        the [resources] timeout is a backstop, not the mechanism.

        Modal streams a Sandbox's output into the app log as it runs -- which
        is what you want for a build -- so this returns "" rather than handing
        back a copy for the caller to print underneath it.
        """
        line = self.shell_command(override)
        sb = modal.Sandbox.create(
            "sh", "-c", line,
            app=self.app,
            image=self.image,
            workdir=self.workdir,
            env={k: str(v) for k, v in self.env.items()},
            **self.sandbox_kwargs,
        )
        self._print_tunnels(sb)
        sb.wait()
        if sb.returncode != 0:
            raise RuntimeError(
                f"{self.name}: command failed ({sb.returncode})\n"
                f"$ {line}\n{sb.stderr.read()}"
            )
        return ""

    def _print_tunnels(self, sb: "modal.Sandbox") -> None:
        """Say where a tunnelled port can be reached, once the sandbox is up.

        `tunnels()` blocks until the Sandbox is scheduled, which is why this
        is called after create and not folded into it. Nothing prints when
        [network] ports is empty, which is every container but the serving
        ones.
        """
        if not self.ports:
            return
        for port, tunnel in sb.tunnels().items():
            print(f"  :{port} -> {tunnel.url}")

    def open_sandbox(self) -> "modal.Sandbox":
        """Start a Sandbox and leave it running, for `scripts/shell`.

        Same workdir and the same [run] env as the real thing: a shell opened
        to debug a container that does not have the container's environment is
        a shell that reproduces something else. `command` is the one part left
        out, because not running it is the point.
        """
        return modal.Sandbox.create(
            "sleep",
            "infinity",
            app=self.app,
            image=self.image,
            workdir=self.workdir,
            env={k: str(v) for k, v in self.env.items()},
            **self.sandbox_kwargs,
        )

    def execute(self, override: str = "") -> str:
        """Run the command in this container. Called remotely, not locally."""
        line = self.shell_command(override)
        result = subprocess.run(
            line,
            shell=True,
            capture_output=True,
            text=True,
            env={**os.environ, **{k: str(v) for k, v in self.env.items()}},
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"{self.name}: command failed ({result.returncode})\n"
                f"$ {line}\n{result.stderr}"
            )
        return result.stdout
