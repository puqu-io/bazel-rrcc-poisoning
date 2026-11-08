def _tpl_impl(rctx):
    rctx.file("BUILD.bazel", 'exports_files(["BUILD.tpl"])\n')
    rctx.file("BUILD.tpl", '# ROOT')
    rctx.file("__config__/BUILD.bazel", 'exports_files(["BUILD.tpl", "defs.bzl"])\n')
    rctx.file("__config__/BUILD.tpl", '# CONFIG')
    rctx.file("__config__/defs.bzl", "# padding\n" + ("# " + "x" * 78 + "\n") * 40)
    return rctx.repo_metadata(reproducible = True)

tpl_repo = repository_rule(implementation = _tpl_impl)

def _x_impl(rctx):
    rctx.template("BUILD.bazel", Label("@tpl//:BUILD.tpl"))

    rctx.file("defs.bzl", "# padding\n" + ("# " + "y" * 90 + "\n") * 40)

    rctx.file("metadata.json", "{}")
    rctx.template("__config__/BUILD.bazel", Label("@tpl//__config__:BUILD.tpl"))
    rctx.template("__config__/defs.bzl", Label("@tpl//__config__:defs.bzl"))
    rctx.file("package.json", "{}")
    return rctx.repo_metadata(reproducible = True)

x_repo = repository_rule(implementation = _x_impl)
