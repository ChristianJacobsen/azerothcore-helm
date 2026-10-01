#!/usr/bin/env python3
"""Pin the images of one flavor in the chart values to a tag and digests.

Edits the tag and digest lines as text: a YAML round trip would drop the
comments that document values.yaml.
"""
import argparse
import pathlib
import re
import sys

VALUES = pathlib.Path(__file__).resolve().parent.parent / "charts" / "azerothcore" / "values.yaml"
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
FLAVORS = ("vanilla", "playerbots")
COMPONENTS = ("worldserver", "authserver", "dbImport", "clientData")


def key_at(line: str, indent: int):
    """The mapping key of a line at exactly this indent, or None."""
    m = re.match(rf"^ {{{indent}}}([A-Za-z0-9_-]+):", line)
    return m.group(1) if m else None


def pin(text: str, flavor: str, component: str, tag: str, digest: str) -> str:
    lines = text.splitlines(keepends=True)
    path = []
    done = set()
    for i, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent % 2:
            continue
        depth = indent // 2
        key = key_at(line, indent)
        if key is None:
            continue
        path = path[:depth] + [key]
        if path[:3] == ["images", flavor, component] and depth == 3 and key in ("tag", "digest"):
            value = tag if key == "tag" else digest
            lines[i] = f'{" " * indent}{key}: "{value}"\n'
            done.add(key)
    if done != {"tag", "digest"}:
        sys.exit(f"images.{flavor}.{component}: tag or digest line not found in {VALUES}")
    return "".join(lines)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--flavor", required=True, choices=FLAVORS)
    p.add_argument("--tag", required=True)
    for component in COMPONENTS:
        p.add_argument(f"--{component}-digest", required=True)
    p.add_argument("--values", type=pathlib.Path, default=VALUES)
    args = p.parse_args()
    text = args.values.read_text()
    for component in COMPONENTS:
        digest = getattr(args, f"{component}_digest")
        if not DIGEST.match(digest):
            sys.exit(f"not a sha256 digest: {digest}")
        text = pin(text, args.flavor, component, args.tag, digest)
    args.values.write_text(text)
    print(f"pinned the {args.flavor} images to {args.tag}")


if __name__ == "__main__":
    main()
