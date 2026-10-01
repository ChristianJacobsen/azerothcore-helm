# Contributing

This file covers the images, the local workflow, the CI, and the releases. For the chart itself, see the [README](README.md).

## Images

The script `build/build-images.sh` builds the images with the Dockerfile of the core (`apps/docker/Dockerfile`). The variable `FLAVOR` selects the core repository and the module that comes with the flavor:

| `FLAVOR` | Core | Module |
| --- | --- | --- |
| `vanilla` | `azerothcore/azerothcore-wotlk` | `mod-ale` |
| `playerbots` | `mod-playerbots/azerothcore-wotlk` | `mod-playerbots` |

Each build makes four images. The sizes are for the vanilla flavor on arm64:

| Image | Contents | Size |
| --- | --- | --- |
| `azerothcore-<flavor>-worldserver` | `worldserver` | 800 MB |
| `azerothcore-<flavor>-authserver` | `authserver` | 350 MB |
| `azerothcore-<flavor>-db-import` | `dbimport`, the MySQL client, and the SQL of the core and the modules | 1.4 GB |
| `azerothcore-<flavor>-client-data` | the script that downloads the client data | 170 MB |

The images must come from the same build, because the SQL updates follow the core revision. The file `build/sources.env` pins the core and module repositories to commits, and Renovate updates the pins.

To build the images, you need Docker with buildx. With a warm compiler cache, a vanilla build took 15 minutes on a 10-core machine. A first build compiles the whole core and takes longer. This command builds the vanilla images, or the flavor and modules of `build/mods.local.yaml` (see the [README](README.md#other-modules)):

```sh
make images
```

To build another flavor, set `FLAVOR`:

```sh
FLAVOR=playerbots make images
```

The script loads the images into the local Docker and writes `build/images.generated.yaml`. That file sets `flavor` and the images. To install the chart with these images, give Helm that file:

```sh
helm install azerothcore charts/azerothcore -n azerothcore --create-namespace \
  -f build/images.generated.yaml -f values.local.yaml
```

The script resolves branch names to commits, so you can also build another revision:

```sh
CORE_REF=master MOD_ALE_REF=master make images
```

Environment variables of `build/build-images.sh`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `FLAVOR` | `flavor` of the mods file, else `vanilla` | `vanilla` or `playerbots` |
| `MODS_FILE` | `build/mods.local.yaml` | The list of extra modules |
| `REGISTRY` | `local` | Image namespace, for example `ghcr.io/you` |
| `TAG` | `<UTC date>-<core commit>` | Image tag |
| `PUSH` | `0` | `1` pushes to `REGISTRY`. Otherwise the script loads the images into Docker |
| `PLATFORMS` | host platform | For example `linux/amd64,linux/arm64`. Two or more platforms need `PUSH=1` |
| `CORE_REF`, `MOD_ALE_REF`, `MOD_PLAYERBOTS_REF` | from `build/sources.env` | Branch, tag, or commit |
| `CACHE_REF` | empty | Registry cache prefix, for example `ghcr.io/you/azerothcore-vanilla-cache:amd64` |

If your cluster cannot pull from the local Docker, push the images to a registry with `REGISTRY` and `PUSH=1`. Then give Helm the generated file, which names the registry.

A rebuild on the same builder compiles only the changed files, because the compiler cache stays on the builder. With `CACHE_REF`, the build layers also go to a registry cache. If the sources and the base image did not change, a build on any machine then skips the compile.

## Local workflow

```sh
make lint        # helm lint
make images      # build the images
make template    # render with build/images.generated.yaml and values.local.yaml
make validate    # server-side dry run against the current cluster
make install     # helm upgrade --install with the same values
make test        # helm test (TCP checks and a login)
make catalogue   # the modules of the catalogue with the most stars
```

The files `values.local.yaml` and `build/mods.local.yaml` are for your local configuration. Git ignores them.

The chart runs the scripts in `charts/azerothcore/files`. Artifact Hub shows the README outside of this repository. In the README, link to other files of the repository with full GitHub URLs.

## CI

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `chart-ci` | pull request, push | lint, render tests, kubeconform, shellcheck, the SRP6 test vectors |
| `images` | weekly, push to `build/` | builds, signs, and publishes the multi-arch images of both flavors |
| `pin-merge` | `chart-ci` passes on the pin pull request | fast-forwards `main` to the pin commit, so that the commit keeps its signature |
| `chart-e2e` | nightly | installs the chart on kind for each flavor with the published images, logs in, and follows the realm list to the worldserver |
| `chart-release` | tag `chart-v*` | signs and pushes the chart to `oci://ghcr.io/christianjacobsen/charts` |

The images workflow publishes the images with the tags `<date>-<core commit>` and `latest`. Then it opens a pull request that pins the new tags and digests of both flavors in `charts/azerothcore/values.yaml`. If one flavor fails to build, the workflow pins none of them.

## Releases

To release the chart, wait until the pin pull request merges. Then push a tag:

```sh
git tag chart-v0.1.0 && git push --tags
```

The release workflow packages the README and the LICENSE with the chart, and it signs the chart with cosign. It also pushes `artifacthub-repo.yml` to the chart repository, so that Artifact Hub shows the chart as a verified publisher. It writes the images of both flavors to the `artifacthub.io/images` annotation, so that Artifact Hub scans them for vulnerabilities.
