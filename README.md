![Supavisor](/docs/images/supavisor-banner.png)

# Supavisor - Postgres connection pooler

## Avvio rapido del pannello locale

Con PostgreSQL già avviato su questo PC:

```bash
mix setup
mix phx.server
```

Apri [http://localhost:4000/admin](http://localhost:4000/admin) e premi
**Accedi in locale**: `admin@localhost` è già compilato.
PostgreSQL resta sulla porta `5432`; Supavisor usa `6543` (transazioni) e `5452` (sessioni).

[Guida completa: avvio locale e servizio Linux senza Docker](docs/development/local-admin.md).

[![Coverage Status](https://coveralls.io/repos/github/supabase/supavisor/badge.svg?branch=main)](https://coveralls.io/github/supabase/supavisor?branch=main)

- [Overview](#overview)
- [Admin UI Branch](#admin-ui-branch)
- [Motivation](#motivation)
- [Architecture](#architecture)
- [Docs](#docs)
- [Features](#features)
- [Future work](#future-work)
- [Acknowledgements](#acknowledgements)
- [Benchmarks](#benchmarks)
- [Inspiration](#inspiration)

## Overview

Supavisor is a scalable, cloud-native Postgres connection pooler. A Supavisor
cluster is capable of proxying millions of Postgres end-client connections into
a stateful pool of native Postgres database connections.

## Admin UI Branch

This branch adds a small Phoenix LiveView admin dashboard at `/admin` for people
who run and manage their own PostgreSQL server with Supavisor in front of it.
The goal is a simple internal UI for day-to-day connection management, not a
full hosted control plane.

![Supavisor admin dashboard](./screenshots/image.png)

The dashboard supports:

- Passwordless admin login with configured admin emails and magic links.
- Listing Supavisor tenant connection profiles.
- Creating, editing, and deleting tenant metadata.
- Managing stored Supavisor users or auth-query manager users.
- Showing concrete connection examples, including Elixir/Ecto `url:` config.
- Optional database provisioning that creates a new PostgreSQL database and
  login role, then creates the matching Supavisor tenant.

Database provisioning is deliberately conservative. It is disabled by default in
global config, requires explicit provisioner credentials, and only allows target
hosts/ports listed in application config. It refuses to overwrite existing
databases or roles. This is useful when Supavisor is deployed on a server you
control and you want the admin dashboard to create both the PostgreSQL database
and the Supavisor connection profile from one form.

Supavisor clients still connect using the PostgreSQL protocol, not HTTP. The
admin dashboard is HTTP, but applications connect to Supavisor with a PostgreSQL
URL such as:

```text
postgresql://my_app_user.my_app:PASSWORD@supavisor-host:6553/my_app_db
```

For Ecto, the UI shows the equivalent tenant connection config:

```elixir
config :vext, MyApp.Repo,
  url: "ecto://my_app_user.my_app:PASSWORD@supavisor-host:6553/my_app_db",
  pool_size: 10
```

For database managers, Supavisor simplifies the task of managing Postgres
clusters by providing easy configuration of highly available Postgres clusters
([todo](#future-work)).

## Motivation

We have several goals with Supavisor:

- **Zero-downtime scaling**: we want to scale Postgres server compute with
  zero-downtime. To do this, we need an external Pooler that can buffer and
  re-route requests while the resizing operation is in progress.
- **Handling modern connection demands**: We need a Pooler that can absorb
  millions of connections. We often see developers connecting to Postgres from
  Serverless environments, and so we also need something that works with both TCP
  and HTTP protocols.
- **Efficiency**: Our customers pay for database processing power, and our goal
  is to maximize their database capacity. While PgBouncer is resource-efficient,
  it still consumes some resources on the database instance. By moving connection
  pooling to a dedicated cluster adjacent to tenant databases, we can free up
  additional resources to better serve customer queries.

## Architecture

Supavisor was designed to work in a cloud computing environment as a highly
available cluster of nodes. Tenant configuration is stored in a highly available
Postgres database. Configuration is loaded from the Supavisor database when a
tenant connection pool is initiated.

Connection pools are dynamic. When a tenant client connects to the Supavisor
cluster the tenant pool is started and all connections to the tenant database
are established. The process ID of the new tenant pool is then distributed to
all nodes of the cluster and stored in an in-memory key-value store. Subsequent
tenant client connections live on the inbound node but connection data is
proxied from the pool node to the client connection node as needed.

Because the count of Postgres connections is constrained only one tenant
connection pool should be alive in a Supavisor cluster. In the case of two
simultaneous client connections starting a pool, as the pool process IDs are
distributed across the cluster, eventually one of those pools is gracefully
shutdown.

The dynamic nature of tenant database connection pools enables high availability
in the event of node outages. Pool processes are monitored by each node. If a
node goes down that process ID is removed from the cluster. Tenant clients will
then start a new pool automatically as they reconnect to the cluster.

This design enables blue-green or rolling deployments as upgrades require. A
single VPC / multiple availability zone topologies is possible and can provide
for greater redundancy when load balancing queries across read replicas are
supported ([todo](#future-work)).

<p align="center">
<img src="https://user-images.githubusercontent.com/8291514/230757493-669bf563-084c-4705-b22e-38d398f4ec05.svg#gh-light-mode-only">
<img src="https://user-images.githubusercontent.com/8291514/230757489-2d2fb07a-1fcb-423b-939e-b0c04e2d4d9b.svg#gh-dark-mode-only">
</p>

## Docs

- [Installation and usage](https://supabase.github.io/supavisor/development/installation/)
- [Environment Variables Documentation](https://supabase.github.io/supavisor/configuration/env/)
- [Metrics](https://supabase.github.io/supavisor/monitoring/metrics/)

## Features

- Fast
  - Within 90% throughput as compared to `PgBouncer` running `pgbench` locally
- Scalable
  - 1 million Postgres connections on a cluster
  - 250_000 idle connections on a single 16 core node with 64GB of ram
- Multi-tenant
  - Connect to multiple different Postgres instances/clusters
- Single-tenant
  - Easy drop-in replacement for `PgBouncer`
- Pool mode support per tenant
  - Transaction
- Cloud-native
  - Cluster-able
  - Resilient during cluster resizing
  - Supports rolling and blue/green deployment strategies
  - NOT run in a serverless environment
  - NOT dependant on Kubernetes
- Observable
  - Easily understand throughput by tenant, tenant database or individual
    connection
  - Prometheus `/metrics` endpoint
- Manageable
  - OpenAPI spec at `/api/openapi`
  - SwaggerUI at `/swaggerui`
- Highly available
  - When deployed as a Supavisor cluster and a node dies connection pools should
    be quickly spun up or already available on other nodes when clients reconnect
- Connection buffering
  - Brief connection buffering for transparent database restarts or failovers

## Future Work

- Load balancing
  - Queries can be load balanced across read-replicas
  - Load balancing is independent of Postgres high-availability management (see
    below)
- Query caching
  - Query results are optionally cached in the pool cluster and returned before
    hitting the tenant database
- Session pooling
  - Like `PgBouncer`
- Multi-protocol Postgres query interface
  - Postgres binary
  - HTTPS
  - Websocket
- Postgres high-availability management
  - Primary database election on primary failure
  - Health checks
  - Push button read-replica configuration
- Config as code
  - Not only for the Supavisor cluster but tenant databases and tenant database
    clusters as well
  - Pulumi / Terraform support

## Benchmarks

### Local Benchmarks

- Running `pgbench` on `PgBouncer` (transaction mode/pool size 60)

```
PGPASSWORD=postgres pgbench -M extended --transactions 100 --jobs 10 --client 100 -h localhost -p 6452 -U postgres postgres
pgbench (15.2, server 14.6 (Debian 14.6-1.pgdg110+1))
starting vacuum...end.
transaction type: <builtin: TPC-B (sort of)>
scaling factor: 1
query mode: extended
number of clients: 100
number of threads: 10
maximum number of tries: 1
number of transactions per client: 100
number of transactions actually processed: 10000/10000
number of failed transactions: 0 (0.000%)
latency average = 510.310 ms
initial connection time = 31.388 ms
tps = 195.959361 (without initial connection time)
```

- Running `pgbench` on `Supavisor` (pool size 60, no logs)

```
PGPASSWORD=postgres pgbench -M extended --transactions 100 --jobs 10 --client 100 -h localhost -p 7654 -U postgres.localhost postgres
pgbench (15.2, server 14.6 (Debian 14.6-1.pgdg110+1))
starting vacuum...end.
transaction type: <builtin: TPC-B (sort of)>
scaling factor: 1
query mode: extended
number of clients: 100
number of threads: 10
maximum number of tries: 1
number of transactions per client: 100
number of transactions actually processed: 10000/10000
number of failed transactions: 0 (0.000%)
latency average = 528.463 ms
initial connection time = 178.591 ms
tps = 189.228103 (without initial connection time)
```

### Load Test

![Supavisor load test virtual users chart](./docs/images/load-test-vus.png)

![Supavisor load test qps chart](./docs/images/load-test-qps.png)

- Supavisor two node cluster
  - 64vCPU / 246RAM
  - Ubuntu 22.04.2 aarch64
- 1 003 200 concurrent client connection
- 20 000+ QPS
- 400 tenant Postgres connection
- `SELECT * FROM (VALUES (1, 'one'), (2, 'two'), (3, 'three')) AS t (num, letter);`
- ~50% CPU utilization (pool owner node)
- 7.8G RAM usage

## Acknowledgements

[José Valim](https://github.com/josevalim) and the [Dashbit](https://dashbit.co/) team were incredibly helpful in informing
the design decisions for Supavisor.

## Inspiration

- [PgBouncer](https://www.pgbouncer.org/)
- [stolon](https://github.com/sorintlab/stolon)
- [pgcat](https://github.com/levkk/pgcat)
- [odyssey](https://github.com/yandex/odyssey)
- [crunchy-proxy](https://github.com/CrunchyData/crunchy-proxy)
- [pgpool](https://www.pgpool.net/mediawiki/index.php/Main_Page)
- [pgagroal](https://github.com/agroal/pgagroal)

## Commercial Inspiration

- [proxysql.com](https://proxysql.com/)
- [Amazon RDS Proxy](https://aws.amazon.com/rds/proxy/)
- [Google Cloud SQL Proxy](https://github.com/GoogleCloudPlatform/cloud-sql-proxy)
