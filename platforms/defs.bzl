# The stock prelude//platforms:default with its cache switches flipped on.
#
# The prelude's own `execution_platform` rule is static Starlark — there is no
# buckconfig key that turns caching on for it — so the rule is copied here and
# its CommandExecutorConfig changed. Everything else mirrors the original
# exactly, so this platform stays configuration-identical to the default.
#
# Whether actions may run on a worker is an attribute now rather than a
# constant. It was false because it had to be: the toolchain named absolute
# paths inside this checkout, which no worker would have. Both compilers are
# dependencies now, so there is something to ship.
load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")

def _execution_platform_impl(ctx: AnalysisContext) -> list[Provider]:
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    cfg = ConfigurationInfo(constraints = constraints, values = {})

    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            local_enabled = ctx.attrs.local_enabled,
            remote_enabled = ctx.attrs.remote_enabled,
            remote_cache_enabled = True,
            allow_cache_uploads = True,
            remote_execution_properties = ctx.attrs.remote_execution_properties,
            remote_execution_use_case = "buck2-default",
            use_windows_path_separators = ctx.attrs.use_windows_path_separators,
        ),
    )

    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(
            platforms = [platform],
            exec_marker_constraint = get_exec_platform_marker(),
        ),
    ]

execution_platform = rule(
    impl = _execution_platform_impl,
    attrs = {
        "cpu_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "local_enabled": attrs.bool(default = True),
        "remote_enabled": attrs.bool(default = False),
        "remote_execution_properties": attrs.dict(attrs.string(), attrs.string(), default = {}),
        "os_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "use_windows_path_separators": attrs.bool(),
    },
)
