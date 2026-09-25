# azerothcore-helm

A Helm chart for [AzerothCore](https://www.azerothcore.org/), a World of
Warcraft 3.3.5a (WotLK) private server. The chart offers selectable image
flavors, including
[mod-playerbots](https://github.com/mod-playerbots/mod-playerbots).

One command to a running server:

```sh
helm install ac oci://ghcr.io/<owner>/charts/azerothcore
```

~15 minutes later (mostly a one-off client-data download), MySQL, the auth
server, and the world server run. The db-import job migrated the databases
and registered the realm.

## Why the chart never compiles anything

AzerothCore C++ modules are compile-time. The build links them statically
into the server binaries. You choose the module list when you configure the
core. There is no plugin mechanism. The "dynamic" module mode is link-time
dynamic linking (experimental), not runtime loading.

This project separates the two concerns:

| Concern | Tool |
| --- | --- |
| Deploy (databases, migrations, client data, services, configuration) | the Helm chart in this repo |
| Build (select and compile mods into images) | the upstream Dockerfile, driven by `build/build-images.sh` locally or by CI |

## Flavors

| `flavor` | Base | Mods | Images |
| --- | --- | --- | --- |
| `vanilla` (default) | `azerothcore/azerothcore-wotlk` | none | upstream `docker.io/acore/ac-wotlk-*` (pinned) |
| `playerbots` | `mod-playerbots/azerothcore-wotlk` @ `Playerbot` | mod-playerbots | `flavorRegistry` you point at (CI- or self-built) |
| custom | your choice | your choice | built with `make images`, referenced via `-f build/images.generated.yaml` |

Lua scripting (ALE, formerly mod-eluna) is built into modern AzerothCore
cores. You can enable it at runtime without a rebuild:

```yaml
worldserver:
  config:
    ALE.Enabled: 1
  elunaScripts:
    existingClaim: my-lua-scripts-pvc   # mounted at .../env/dist/lua_scripts
```

## Quick start

### Vanilla (zero builds)

```sh
helm install ac charts/azerothcore -n ac --create-namespace
kubectl -n ac get pods -w
```

The first boot takes ~10–15 minutes (client-data download, SQL migrations,
world load). This is normal. Later restarts take a few minutes.

### Playerbots (zero builds, if images exist)

```sh
helm install ac charts/azerothcore -n ac --create-namespace \
  --set flavor=playerbots \
  --set flavorRegistry=ghcr.io/<your-org>
```

`flavorRegistry` must host `ac-wotlk-{worldserver,authserver,db-import}:playerbots`
images. The CI of this repo publishes them (`.github/workflows/images.yaml`,
weekly and on-demand, multi-arch), or you can build them locally (next
section). If you select a non-vanilla flavor without a registry, the chart
fails with a clear message.

A worldserver with thousands of bots needs more memory than the defaults:

```yaml
worldserver:
  resources:
    requests: { memory: 4Gi }
    limits:   { memory: 8Gi }
```

### Custom catalogue mods (local build)

Pick mods from the [catalogue](https://www.azerothcore.org/catalogue.html).
The command `make catalogue` lists the most-starred mods. Then write
`build/mods.yaml`:

```yaml
# build/mods.yaml
flavor: playerbots   # or vanilla
mods:
  - https://github.com/azerothcore/mod-solocraft.git
  - https://github.com/azerothcore/mod-autobalance.git@master
```

```sh
make images                 # ~60–90 min first time; incremental after
helm install ac charts/azerothcore -n ac --create-namespace \
  -f build/images.generated.yaml -f your-values.yaml
```

The script clones the correct base. It selects the Playerbot fork when the
mod list needs it, and it refuses mod-playerbots on vanilla, because that
combination cannot work. It compiles with the upstream Dockerfile via
`docker buildx`, loads the images into your local Docker, and writes
`build/images.generated.yaml` for Helm. Build caches live in the buildkit of
dockerd. If you change the mod list later, the build recompiles only what
changed.

Environment overrides: `REGISTRY`, `TAG`, `PUSH=1`,
`PLATFORMS=linux/amd64,linux/arm64` (multi-arch requires `PUSH=1`).

> mod-playerbots requires the fork. It cannot run on a vanilla core.
> The build script and the chart both refuse that combination.

## Connecting a game client

1. Get the service addresses:
   ```sh
   kubectl -n ac get svc ac-azerothcore-authserver ac-azerothcore-worldserver
   ```
2. Point the `realmlist.wtf` of the client at the authserver address
   (NodePort or LoadBalancer).
3. The realm address stored in the database must be the address that clients
   use to reach the worldserver. The default is `127.0.0.1` (correct when you
   play on the same machine). For LAN or WAN players:
   ```sh
   helm upgrade ac charts/azerothcore -n ac --reuse-values \
     --set dbInit.realm.address=<your LAN or WAN IP>
   ```

### Creating your first (GM) account

The worldserver runs an interactive console. SOAP cannot create the first
account, because SOAP authentication itself requires a GM account. Use the
console instead:

```sh
kubectl -n ac attach -it deploy/ac-azerothcore-worldserver -c worldserver
AC> account create <user> <password>
AC> account set gmlevel <user> 3 -1
AC> account set addon <user> 2
# detach with ctrl-p ctrl-q  (NOT ctrl-c: it kills the worldserver)
```

## Configuration

You can set any key from `worldserver.conf.dist` or `authserver.conf.dist`
verbatim, including module configuration keys. The chart converts each key to
the `AC_*` environment variable that the core reads natively:

```yaml
worldserver:
  config:
    Rate.XP.Kill: 3
    AllowTwoSide.Interaction.Calendar: 1
    MaxPlayerLevel: 80
authserver:
  config:
    WrongPass.MaxCount: 5
```

(`Rate.XP.Kill` becomes `AC_RATE_XP_KILL`. Use `1` and `0`, not `true` and
`false`.)

Use `worldserver.extraEnv` and `authserver.extraEnv` for environment variables
that have no configuration key.

### Storage

- MySQL: a bundled `mysql:8.4` StatefulSet with an 8 Gi PVC. To use your own
  server, set `mysql.enabled=false` and configure `externalDatabase`.
- Client data: a 20 Gi PVC, populated once by a download Job
  (`helm.sh/resource-policy: keep`, so it survives `helm uninstall`).
  To use your own PVC, set `clientData.existingClaim`.
  To skip the download, set `clientData.download=false`.

Both default to `ReadWriteOnce` and the default StorageClass of the cluster.
This works for single-node clusters. For multi-node clusters, use
`existingClaim` with a `ReadWriteMany` volume.

### Exposing the game ports (Ingress? Gateway API?)

The auth (3724) and world (8085) protocols are raw TCP, not HTTP. Ingress is
HTTP-only and cannot route them, so the chart does not offer an Ingress. Do
not expose the SOAP port through an Ingress either.

Options:

1. NodePort (default): works everywhere and needs nothing extra.
2. LoadBalancer: set `*.service.type=LoadBalancer` on cloud clusters.
3. Gateway API TCPRoute: set `gateway.enabled=true` and `gateway.parentRefs`.
   A Gateway-capable controller is a common day-one install, so this is often
   the best option. Your controller must route raw TCP:

   | Controller | TCPRoute | Notes |
   | --- | --- | --- |
   | NGINX Gateway Fabric | Yes | full support in v2.x (a different product from ingress-nginx) |
   | Envoy Gateway | Yes | experimental-channel CRDs |
   | Kong Gateway | Yes | |
   | Traefik v3 | Yes | needs `providers.kubernetesGateway.experimentalChannel: true` and experimental-channel CRDs, or its Gateway provider does not start |
   | ingress-nginx | No | no Gateway API at all. Use its `tcp-services` ConfigMap instead |
   | Caddy ingress | No | HTTP only |

   TCPRoute itself is experimental-channel (`v1alpha2`) in the upstream
   Gateway API. Some controllers also serve it at `v1`. The chart renders the
   version that your cluster serves. If the cluster serves neither version,
   the chart fails with a clear message. If you enable the gateway, point
   `dbInit.realm.address` at the external address of the Gateway and switch
   the services back to `ClusterIP`.

### Apple Silicon / arm64 note

Upstream `acore/*` images are amd64-only. On arm64 machines you have two
options:

- Pull the images for the amd64 platform before you install:
  `docker pull --platform linux/amd64 <image>`. On OrbStack k3s and Docker
  Desktop Kubernetes, the cluster shares the Docker image store, and the
  images run under emulation.
- Build native arm64 images with `make images`. The default platform is the
  platform of the host, so `FLAVOR=vanilla` with no mods gives a native
  vanilla build.

The `playerbots` flavor images from CI are multi-arch (amd64 and arm64).

## Upgrades

`helm upgrade` re-runs the db-import Job (Jobs are named per release revision
to work around Job immutability), so the SQL migrations track the image
version. The client-data Job re-runs too and is a quick no-op unless the data
version changed.

## Image version policy

The file `values.yaml` pins every image by tag, and the upstream images also
by digest. Renovate (docker datasource on the `# renovate:` annotations) and
the chart releases handle the bumps.

## Repository layout

```
charts/azerothcore/     the Helm chart
build/                  mod selection + image build tool (mods.yaml, build-images.sh)
.github/workflows/      images → GHCR (weekly), chart CI, nightly kind e2e, chart release (OCI)
Makefile                lint / template / validate / images / catalogue
```

## Development

```sh
make lint          # helm lint
make validate      # helm template | kubectl apply --dry-run=server (needs a cluster)
make catalogue     # browse top catalogue mods
helm test ac -n ac # TCP connectivity test against a running release
```

CI runs lint, template checks, kubeconform, and shellcheck on each pull
request. It runs a full kind install every night and builds the playerbots
flavor images every week.

## Known limitations (by design)

- One realm per release. Single-replica servers.
- No automated account creation. SOAP cannot create the first account, by the
  design of AzerothCore (see above).
- C++ mod changes always require an image rebuild. Only Lua scripts and
  configuration are adjustable at runtime.
- No built-in backup CronJob yet. Use `mysqldump` against the MySQL pod (see
  the AzerothCore backup docs).
