#!/usr/bin/env python3
"""Reads AC entries and Tree blobs from a bazel-remote HTTP endpoint.

Python 3 standard library only. It decodes the few protobuf fields it needs.

Commands:
  final-key  HTTP_BASE LOG [NAME]
                             Find the last "GRPC AC PUT" in the bazel-remote log
                             whose output directory has the file NAME (default
                             defs.bzl) in its root. This is the final entry of @x.
                             Prints "<ac_key> <tree_hash>".
  ac-tree    HTTP_BASE KEY   Prints the tree hash of the output directory.
  tree       HTTP_BASE HASH  Lists all files, symlinks and directories of a Tree
                             blob, with their paths, at any depth.
  file       HTTP_BASE HASH NAME
                             Prints the digest hash of file NAME in the Tree root.

Keep the bazel-remote default for HTTP AC validation. With
--disable_http_ac_validation, bazel-remote serves /ac/ from a separate "raw"
namespace, and this tool cannot find the entries that Bazel wrote with gRPC.
"""
import re
import sys
import urllib.error
import urllib.request


def http_get(base, path):
    try:
        with urllib.request.urlopen(base.rstrip("/") + path, timeout=10) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def varint(buf, i):
    shift = result = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, i
        shift += 7


def fields(buf):
    """Yields (field_number, wire_type, value) for one message."""
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        num, wt = key >> 3, key & 7
        if wt == 0:
            v, i = varint(buf, i)
        elif wt == 2:
            n, i = varint(buf, i)
            v = buf[i : i + n]
            i += n
        elif wt == 1:
            v = buf[i : i + 8]
            i += 8
        elif wt == 5:
            v = buf[i : i + 4]
            i += 4
        else:
            raise ValueError("unsupported wire type %d" % wt)
        yield num, wt, v


def digest(buf):  # Digest: hash=1, size_bytes=2
    h, s = "", 0
    for n, _, v in fields(buf):
        if n == 1:
            h = v.decode()
        elif n == 2:
            s = v
    return h, s


def output_dir_trees(action_result):  # ActionResult.output_directories=3
    out = []
    for n, _, v in fields(action_result):
        if n == 3:
            path, tree = "", None
            for m, _, w in fields(v):  # OutputDirectory: path=1, tree_digest=3
                if m == 1:
                    path = w.decode()
                elif m == 3:
                    tree = digest(w)
            out.append((path, tree))
    return out


def dir_entries(directory_blob):
    """Yields (kind, name, extra) for one Directory message.

    Directory: files=1, directories=2, symlinks=3.
    FileNode / DirectoryNode: name=1, digest=2. SymlinkNode: name=1, target=2.
    """
    for m, _, w in fields(directory_blob):
        name, dig, target = "", None, ""
        for k, _, x in fields(w):
            if k == 1:
                name = x.decode()
            elif k == 2 and m in (1, 2):
                dig = digest(x)
            elif k == 2 and m == 3:
                target = x.decode()
        if m == 1:
            yield "file", name, dig
        elif m == 2:
            yield "dir", name, dig
        elif m == 3:
            yield "symlink", name, target


def walk_tree(tree_blob):
    """Yields (kind, path, extra) for each entry of a Tree, depth first.

    Tree: root=1, children=2. A child Directory is found by the SHA-256 of
    its serialized bytes, which is the digest in its DirectoryNode. Each
    directory line comes directly before its contents.
    """
    import hashlib
    root, children = b"", {}
    for n, _, v in fields(tree_blob):
        if n == 1:
            root = v
        elif n == 2:
            children[hashlib.sha256(v).hexdigest()] = v

    def walk(prefix, blob):
        for kind, name, extra in sorted(dir_entries(blob), key=lambda e: e[1]):
            path = prefix + name
            yield kind, path, extra
            if kind == "dir":
                child = children.get(extra[0]) if extra else None
                if child is None:
                    yield "missing", path, extra
                else:
                    yield from walk(path + "/", child)

    yield from walk("", root)


def root_entries(tree_blob):  # Tree.root=1 -> Directory
    for n, _, v in fields(tree_blob):
        if n != 1:
            continue
        for m, _, w in fields(v):  # Directory: files=1, directories=2, symlinks=3
            name, dig, target = "", None, ""
            for k, _, x in fields(w):
                if k == 1:
                    name = x.decode()
                elif k == 2 and m in (1, 2):
                    dig = digest(x)
                elif k == 2 and m == 3:
                    target = x.decode()
            if m == 1:
                yield "file", name, dig
            elif m == 2:
                yield "dir", name, dig
            elif m == 3:
                yield "symlink", name, target


def cmd_final_key(base, log, name="defs.bzl"):
    keys = re.findall(r"GRPC AC PUT ([0-9a-f]{64}) OK", open(log).read())
    seen = set()
    for key in reversed(keys):
        if key in seen:
            continue
        seen.add(key)
        ar = http_get(base, "/ac/" + key)
        if ar is None:
            continue
        for _, tree in output_dir_trees(ar):
            blob = http_get(base, "/cas/" + tree[0])
            if blob is None:
                continue
            names = [n for kind, n, _ in root_entries(blob) if kind == "file"]
            if name in names:
                print(key, tree[0])
                return 0
    print("no AC entry has a Tree with %s in its root (%d AC PUTs in the log)"
          % (name, len(seen)), file=sys.stderr)
    return 1


def cmd_ac_tree(base, key):
    ar = http_get(base, "/ac/" + key)
    if ar is None:
        print("NOT_FOUND")
        return 1
    print(output_dir_trees(ar)[0][1][0])
    return 0


def cmd_tree(base, h):
    blob = http_get(base, "/cas/" + h)
    if blob is None:
        print("    (tree blob not found)")
        return 1
    count = 0
    for kind, path, extra in walk_tree(blob):
        count += 1
        if kind == "file":
            print("    %s (%d bytes)" % (path, extra[1]))
        elif kind == "dir":
            print("    %s/" % path)
        elif kind == "symlink":
            print("    %s -> %s" % (path, extra))
        else:
            print("    %s/ (child directory not in the Tree)" % path)
    if not count:
        print("    (empty)")
    return 0


def cmd_file(base, h, wanted):
    for kind, name, extra in root_entries(http_get(base, "/cas/" + h)):
        if kind == "file" and name == wanted:
            print(extra[0])
            return 0
    return 1


def main(argv):
    cmd, base, *rest = argv[1:]
    return {
        "final-key": cmd_final_key,
        "ac-tree": cmd_ac_tree,
        "tree": cmd_tree,
        "file": cmd_file,
    }[cmd](base, *rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
