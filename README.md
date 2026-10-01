# azerothcore-helm

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/azerothcore)](https://artifacthub.io/packages/helm/azerothcore/azerothcore)

A Helm chart for [AzerothCore](https://www.azerothcore.org/), a World of Warcraft server for Wrath of the Lich King (3.3.5a).

The chart runs MySQL, the authserver (the login server), and the worldserver. Two Jobs prepare the data: one creates the databases and applies the SQL updates, and one downloads the client data (the maps and game tables that the worldserver reads).

This repository builds the images with the Dockerfile of the core, in two flavors. The vanilla flavor is the core with [mod-ale](https://github.com/azerothcore/mod-ale), the Lua engine, like the images of AzerothCore. The playerbots flavor is the [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots) fork of the core.

## Quick start

You need a Kubernetes cluster, Helm 3.8 or later, and a 3.3.5a game client.

1. Write a values file. It tells the chart the flavor and which account to create.

   ```yaml
   # values.local.yaml
   flavor: vanilla              # vanilla or playerbots
   dbInit:
     accounts:
       - username: admin
         password: change-me
         gmlevel: 3
   ```

2. Install the chart:

   ```sh
   helm install azerothcore oci://ghcr.io/christianjacobsen/charts/azerothcore \
     -n azerothcore --create-namespace -f values.local.yaml
   kubectl -n azerothcore get pods -w
   ```

3. Wait for the two Jobs to complete. Then the worldserver starts.

4. Make sure that the chart works:

   ```sh
   helm test azerothcore -n azerothcore --logs
   ```

   The test connects to both servers. If `dbInit.accounts` has an account, the test also logs in with it, and the realm must be online.

5. In the client folder, set `realmlist.wtf` to the address of the authserver service. Then log in as `admin`.

On a 10-core machine with a fast link, the first install took about 2 minutes. The world loads in seconds.

The chart values pin the images that the CI of this repository publishes to `ghcr.io/christianjacobsen`. To build your own images, see [CONTRIBUTING.md](https://github.com/ChristianJacobsen/azerothcore-helm/blob/main/CONTRIBUTING.md).

## Flavors

The `flavor` value selects the images:

| `flavor` | Core | Module |
| --- | --- | --- |
| `vanilla` (default) | [azerothcore-wotlk](https://github.com/azerothcore/azerothcore-wotlk) | mod-ale |
| `playerbots` | [mod-playerbots/azerothcore-wotlk](https://github.com/mod-playerbots/azerothcore-wotlk), branch `Playerbot` | mod-playerbots |

mod-playerbots needs changes to the core, so it works with the playerbots flavor only. The playerbots flavor has a fourth database, `acore_playerbots`. The worldserver fills it on the first start.

### Other modules

AzerothCore compiles its modules into the server binaries. For other modules from the [catalogue](https://www.azerothcore.org/catalogue.html), build your own images. List the modules in `build/mods.local.yaml`. Git ignores this file.

```yaml
# build/mods.local.yaml
flavor: playerbots          # vanilla or playerbots
mods:
  - https://github.com/azerothcore/mod-transmog
  - https://github.com/azerothcore/mod-autobalance@master   # a branch, tag, or commit
```

Then build the images and install the chart with the file that the build writes:

```sh
make images
helm install azerothcore charts/azerothcore -n azerothcore --create-namespace \
  -f build/images.generated.yaml -f values.local.yaml
```

`make catalogue` lists the modules with the most stars. For the build variables, see [CONTRIBUTING.md](https://github.com/ChristianJacobsen/azerothcore-helm/blob/main/CONTRIBUTING.md).

## What the chart deploys

| Component | Kind | Purpose |
| --- | --- | --- |
| `mysql` | StatefulSet | MySQL 8.4 with the AzerothCore databases (optional, see [Database](#database)) |
| `db-init` | Job | Creates the databases, applies the SQL updates, sets the realm, and creates accounts |
| `client-data` | Job | Downloads the client data into the data volume |
| `authserver` | Deployment and Service | The login server (port 3724) |
| `worldserver` | Deployment and Service | The world server (port 8085) |

The server pods wait until the Jobs of their release revision are complete.

## Client data

The worldserver needs four kinds of data from the game client: dbc files (game tables), maps, vmaps (models for line of sight), and mmaps (navigation meshes for path finding). The client-data Job downloads the release that the core expects from [wowgaming/client-data](https://github.com/wowgaming/client-data). The download is 1.1 GB, and it unpacks to 3.1 GB. If the data volume holds that release already, the Job completes in seconds.

The `clientData.source` value selects what the Job does:

| `source` | What the Job does |
| --- | --- |
| `download` (default) | Downloads and unpacks the client data |
| `none` | No Job. The data volume holds the data already, for example data that you extracted from your own client |

The chart selects the data volume in this order:

1. `clientData.volume`: any Kubernetes volume source, for example NFS.
2. `clientData.existingClaim`: a PVC that you manage.
3. A PVC that the chart creates from `clientData.storage` (20 GiB, ReadWriteOnce, the default storage class).

## Database

By default, the chart deploys MySQL 8.4 with a 10 GiB volume. It generates the root password and the password of the `acore` user, and it keeps both in a Secret.

To use your own MySQL or MariaDB server:

```yaml
mysql:
  enabled: false
externalDatabase:
  host: mysql.example.com
  port: 3306
  adminUser: root          # optional, see below
database:
  user: acore
  existingSecret: azerothcore-db   # keys: password, admin-password
```

If you set `adminUser`, the db-init Job creates the databases and the `acore` user, and it grants the access. If you do not set it, the databases must exist, and `database.user` must be able to create tables in them. The databases are `acore_auth`, `acore_world`, `acore_characters`, and for the playerbots flavor `acore_playerbots`. `database.names` changes the names.

Do not use `;` in the password. AzerothCore uses it to separate the fields of its connection strings.

The bundled MySQL runs with a few extra arguments, and `mysql.extraArgs` in `values.yaml` gives the reasons. Only MySQL 8.4 is tested.

### What the db-init Job does

The db-init Job runs on every install and upgrade, and it is safe to run many times. It creates the databases and the database user. Then it runs dbimport, a tool of the core. dbimport fills empty databases and applies the SQL updates of the core and the modules that a database does not have yet. Last, the Job sets the realm in the realm list and creates your accounts.

## Accounts

The base SQL of AzerothCore contains no accounts. The Job creates the accounts in `dbInit.accounts`:

```yaml
dbInit:
  accounts:
    - username: admin
      password: change-me       # stored in a Secret by the chart
      gmlevel: 3                # 0 player, 1 moderator, 2 game master, 3 administrator
    - username: friend
      existingSecret: my-accounts
      passwordKey: friend-password
```

If an account does not exist, the Job creates it. The Job never changes the password of an existing account, because players can change their password in the game. It sets `gmlevel` for all realms on every run. Names have 17 characters at most, passwords have 16 at most, and neither is case-sensitive.

You can also use the worldserver console:

```sh
kubectl -n azerothcore attach -it deploy/azerothcore-worldserver -c worldserver
account create <user> <password>
account set gmlevel <user> 3 -1
```

To detach, press ctrl-p ctrl-q. Do not press ctrl-c, because it stops the worldserver.

Warning: do not type passwords in the attached console. The console echoes your input, and the container log keeps it. Use `dbInit.accounts`, or the remote consoles (see [Remote consoles](#remote-consoles)).

## Configuration

You can set any key from `worldserver.conf.dist` and the module configuration files (`worldserver.config`), and from `authserver.conf.dist` (`authserver.config`). Use the key exactly as the file writes it:

```yaml
worldserver:
  config:
    Rate.XP.Kill: 3
    AllowTwoSide.Interaction.Calendar: 1
authserver:
  config:
    WrongPass.MaxCount: 5
```

The chart renders each key as the environment variable that the core reads, for example `AC_RATE_XP_KILL`. It renders `true` and `false` as 1 and 0. The chart sets the database connections, the data folder, the ports, and the remote consoles. For environment variables without a configuration key, use `worldserver.extraEnv` and `authserver.extraEnv`.

### Playerbots

```yaml
flavor: playerbots
playerbots:
  config:
    AiPlayerbot.MinRandomBots: 100
    AiPlayerbot.MaxRandomBots: 100
worldserver:
  resources:
    limits:
      memory: 8Gi
```

The chart lowers the number of random bots from 500 to 50. More bots need more memory for the worldserver. With 50 bots, the worldserver used about 3.9 GiB, and the default limit is 6 GiB.

### Lua scripts

The vanilla images include mod-ale. To load Lua scripts, put them in a ConfigMap or another volume, and set `worldserver.luaScripts`:

```sh
kubectl -n azerothcore create configmap lua-scripts --from-file=scripts/
```

```yaml
worldserver:
  luaScripts:
    configMap:
      name: lua-scripts
```

The chart points `ALE.ScriptPath` at the volume. After you change the scripts, restart the worldserver.

### Remote consoles

The worldserver has two remote consoles: SOAP (`worldserver.soap.enabled`) and a telnet console (`worldserver.remoteAccess.enabled`). The chart exposes them only inside the cluster, on the Service `<release>-worldserver-admin`. Both need an account with gmlevel 3:

```sh
kubectl -n azerothcore port-forward svc/azerothcore-worldserver-admin 3443:3443
telnet 127.0.0.1 3443     # log in with the GM account, then: account create <user> <password>
```

## Connecting a game client

The game protocols are raw TCP. Ingress routes HTTP only, so the chart does not offer an Ingress.

The client connects to two addresses:

1. The address in `realmlist.wtf`, which is the authserver service. The client uses port 3724.
2. The realm address and port from the realm list, which is the worldserver service. `dbInit.realm.address` and `dbInit.realm.port` set them.

Both Services are of type LoadBalancer by default, so they listen on the standard ports. On clusters without a load balancer, use NodePort services with fixed ports:

```yaml
worldserver:
  service:
    type: NodePort
    nodePort: 30085
dbInit:
  realm:
    address: 192.168.1.20    # a node address that the clients can reach
```

If `dbInit.realm.port` is empty, the chart uses the `nodePort` of the worldserver service (for NodePort) or its port. Clients expect the auth port 3724, so give the authserver port 3724 on the address in `realmlist.wtf`. Every upgrade restarts the authserver, so a new realm address takes effect at once.

To test both addresses without a game client, run the login test on your machine with Python 3:

```sh
python3 charts/azerothcore/files/auth-check.py --host <authserver address> \
  --user admin --password change-me --check-world
```

### Gateway API

A Gateway controller that supports TCPRoute can route the two ports. TCPRoute is in the experimental channel of the Gateway API, so the cluster needs the experimental CRDs. A TCP listener cannot tell two routes apart, so each game port needs its own listener on the Gateway:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: games
  namespace: gateway-system
spec:
  gatewayClassName: <your gateway class>
  listeners:
    - name: wow-auth
      protocol: TCP
      port: 3724
      allowedRoutes:
        namespaces:
          from: All
    - name: wow-world
      protocol: TCP
      port: 8085
      allowedRoutes:
        namespaces:
          from: All
```

The chart values attach one TCPRoute to each listener:

```yaml
gateway:
  enabled: true
  parentRefs:
    authserver:
      - name: games
        namespace: gateway-system
        sectionName: wow-auth     # a TCP listener on port 3724
    worldserver:
      - name: games
        namespace: gateway-system
        sectionName: wow-world    # a TCP listener on port 8085
authserver:
  service:
    type: ClusterIP
worldserver:
  service:
    type: ClusterIP
dbInit:
  realm:
    address: <Gateway address>
```

## Upgrades

`helm upgrade` runs both Jobs again. The db-init Job applies the new SQL updates. The client-data Job finds the data release on the volume and completes in seconds. Every upgrade restarts both servers.

## Uninstall

```sh
helm uninstall azerothcore -n azerothcore
```

Helm keeps three things: the MySQL volume (`data-azerothcore-mysql-0`), the data volume (`azerothcore-client-data`), and the database Secret (`azerothcore-db`). A reinstall with the same release name uses them again. To delete everything, delete them by hand:

```sh
kubectl -n azerothcore delete pvc data-azerothcore-mysql-0 azerothcore-client-data
kubectl -n azerothcore delete secret azerothcore-db
```

## Signatures

Each chart version and image carries a keyless cosign signature from this repository. To make sure that a chart comes from here, run:

```sh
cosign verify ghcr.io/christianjacobsen/charts/azerothcore:<version> \
  --certificate-identity-regexp '^https://github\.com/ChristianJacobsen/azerothcore-helm/\.github/workflows/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

The same command works for the images.

## Limits

- One realm per release, and one replica of each server.
- The chart has no backup job yet. Use `mysqldump` against the MySQL pod.
- The data volume uses ReadWriteOnce by default. That works on one node. On clusters with more nodes, use a ReadWriteMany volume through `clientData.existingClaim`, or keep the Job and the worldserver on one node.

## License

The chart uses the GPL-2.0-or-later license, the same as AzerothCore. See [LICENSE](https://github.com/ChristianJacobsen/azerothcore-helm/blob/main/LICENSE).
