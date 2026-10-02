#!/usr/bin/env python3
"""Pin the images of one flavor, or one other image, in the chart values to a tag and digests.

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
# The other images that the images workflow builds, with their key in the values.
IMAGES = {"mysql": ("mysql", "image"), "python": ("images", "python")}


def key_at(line: str, indent: int):
    """The mapping key of a line at exactly this indent, or None."""
    m = re.match(rf"^ {{{indent}}}([A-Za-z0-9_-]+):", line)
    return m.group(1) if m else None


def pin(text: str, keys: tuple, tag: str, digest: str) -> str:
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
        if tuple(path[:depth]) == keys and depth == len(keys) and key in ("tag", "digest"):
            value = tag if key == "tag" else digest
            lines[i] = f'{" " * indent}{key}: "{value}"\n'
            done.add(key)
    if done != {"tag", "digest"}:
        sys.exit(f"{'.'.join(keys)}: tag or digest line not found in {VALUES}")
    return "".join(lines)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--flavor", choices=FLAVORS)
    p.add_argument("--image", choices=IMAGES)
    p.add_argument("--tag", required=True)
    for component in COMPONENTS:
        p.add_argument(f"--{component}-digest", help="with --flavor")
    p.add_argument("--digest", help="with --image")
    p.add_argument("--values", type=pathlib.Path, default=VALUES)
    args = p.parse_args()
    if args.image:
        digests = {IMAGES[args.image]: args.digest}
    elif args.flavor:
        digests = {
            ("images", args.flavor, component): getattr(args, f"{component}_digest")
            for component in COMPONENTS
        }
    else:
        p.error("give --flavor or --image")
    text = args.values.read_text()
    for keys, digest in digests.items():
        if not DIGEST.match(digest or ""):
            sys.exit(f"{'.'.join(keys)}: not a sha256 digest: {digest}")
        text = pin(text, keys, args.tag, digest)
    args.values.write_text(text)
    pinned = f"the {args.image} image" if args.image else f"the {args.flavor} images"
    print(f"pinned {pinned} to {args.tag}")


if __name__ == "__main__":
    main()
