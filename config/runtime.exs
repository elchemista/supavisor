import Config

require Logger

parse_integer_list = fn numbers when is_binary(numbers) ->
  numbers
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_integer/1)
end

parse_boolean = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "true" -> true
    "false" -> false
    _ -> raise "#{name} must be true or false"
  end
end

if System.get_env("LOCAL_ONNX_ENABLED") != nil do
  config :supavisor, Supavisor.Services.LocalModels,
    enabled: parse_boolean.("LOCAL_ONNX_ENABLED", false)
end

if directory = System.get_env("LOCAL_ONNX_MODEL_DIR") do
  unless Path.type(directory) == :absolute do
    raise "LOCAL_ONNX_MODEL_DIR must be an absolute directory containing stt, tts and ai"
  end

  config :supavisor, Supavisor.Services.LocalModels, directory: directory
end

if config_env() == :prod do
  for name <- ~w(DATABASE_URL VAULT_ENC_KEY) do
    if System.get_env(name) in [nil, ""], do: raise("Environment variable #{name} is missing")
  end
end

if key = System.get_env("VAULT_ENC_KEY") do
  if byte_size(key) != 32, do: raise("VAULT_ENC_KEY must contain exactly 32 bytes")
end

db_socket_options =
  if System.get_env("SUPAVISOR_DB_IP_VERSION") == "ipv6",
    do: [:inet6],
    else: [:inet]

secret_key_base =
  if config_env() in [:dev, :test] do
    "3S1V5RyqQcuPrMVuR4BjH9XBayridj56JA0EE6wYidTEc6H84KSFY6urVX7GfOhK"
  else
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """
  end

config :supavisor, SupavisorWeb.Endpoint,
  server: config_env() != :test,
  http: [
    port: String.to_integer(System.get_env("PORT") || "4000"),
    compress: true,
    transport_options: [
      max_connections: String.to_integer(System.get_env("MAX_CONNECTIONS") || "1000"),
      num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
      socket_opts: [
        System.get_env("ADDR_TYPE", "inet")
        |> tap(fn addr_type ->
          if addr_type not in ["inet", "inet6"] do
            raise "ADDR_TYPE env var is invalid: #{inspect(addr_type)}"
          end
        end)
        |> String.to_atom()
      ]
    ]
  ],
  secret_key_base: secret_key_base

if bind_address = System.get_env("HTTP_BIND_ADDRESS") do
  case :inet.parse_address(String.to_charlist(bind_address)) do
    {:ok, address} -> config :supavisor, SupavisorWeb.Endpoint, http: [ip: address]
    _ -> raise "HTTP_BIND_ADDRESS must be an IPv4 or IPv6 address"
  end
end

if bind_address = System.get_env("PROXY_BIND_ADDRESS") do
  case :inet.parse_address(String.to_charlist(bind_address)) do
    {:ok, address} -> config :supavisor, :proxy_bind_address, address
    _ -> raise "PROXY_BIND_ADDRESS must be an IPv4 or IPv6 address"
  end
end

if config_env() != :test do
  config :supavisor, :trust_proxy_headers, parse_boolean.("TRUST_PROXY_HEADERS", false)
  config :supavisor, :admin_email_login_enabled, System.get_env("SMTP_HOST") not in [nil, ""]

  base_url =
    System.get_env("ADMIN_BASE_URL", "http://localhost:#{System.get_env("PORT", "4000")}")

  uri = URI.parse(base_url)

  unless uri.scheme in ["http", "https"] and is_binary(uri.host) and
           uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
           uri.path in [nil, "", "/"] do
    raise "ADMIN_BASE_URL must be an http(s) origin, for example https://db.example.com"
  end

  config :supavisor, SupavisorWeb.Endpoint,
    url: [scheme: uri.scheme, host: uri.host, port: uri.port],
    check_origin: [String.trim_trailing(base_url, "/")]

  config :supavisor, SupavisorWeb.AdminAuth,
    admin_emails:
      System.get_env("ADMIN_EMAILS", if(config_env() == :dev, do: "admin@localhost", else: ""))
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1),
    base_url: base_url,
    email_from: {"Supavisor Admin", System.get_env("ADMIN_EMAIL_FROM", "admin@localhost")}

  config :supavisor, :public_pooler_host, System.get_env("POOLER_HOST", uri.host)

  if System.get_env("ADMIN_PROVISIONING_ENABLED") != nil do
    config :supavisor, SupavisorWeb.AdminProvisioning,
      enabled: parse_boolean.("ADMIN_PROVISIONING_ENABLED", false)
  end

  if host = System.get_env("ADMIN_POSTGRES_HOST") do
    config :supavisor, SupavisorWeb.AdminProvisioning,
      allowed_targets: [{host, String.to_integer(System.get_env("ADMIN_POSTGRES_PORT", "5432"))}],
      provisioner: [
        username: System.fetch_env!("ADMIN_POSTGRES_USER"),
        password: System.fetch_env!("ADMIN_POSTGRES_PASSWORD"),
        database: System.get_env("ADMIN_POSTGRES_DATABASE", "postgres"),
        ssl: parse_boolean.("ADMIN_POSTGRES_SSL", false)
      ]
  end

  if relay = System.get_env("SMTP_HOST") do
    config :supavisor, Supavisor.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: relay,
      port: String.to_integer(System.get_env("SMTP_PORT", "587")),
      username: System.get_env("SMTP_USERNAME", ""),
      password: System.get_env("SMTP_PASSWORD", ""),
      auth: if(System.get_env("SMTP_USERNAME") in [nil, ""], do: :never, else: :always),
      ssl: parse_boolean.("SMTP_SSL", false),
      tls: if(parse_boolean.("SMTP_SSL", false), do: :never, else: :always)
  end
end

topologies = []

topologies =
  if System.get_env("DNS_POLL") do
    dns_poll = [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        polling_interval: 5_000,
        query: System.get_env("DNS_POLL"),
        node_basename:
          System.get_env("NODE_NAME") || System.get_env("FLY_APP_NAME") || "supavisor"
      ]
    ]

    Keyword.put(topologies, :dns_poll, dns_poll)
  else
    topologies
  end

topologies =
  if System.get_env("CLUSTER_NODES") do
    epmd = [
      strategy: Cluster.Strategy.Epmd,
      config: [
        hosts:
          System.get_env("CLUSTER_NODES", "")
          |> String.split(",")
          |> Enum.map(&String.to_atom/1)
      ],
      connect: {:net_kernel, :connect_node, []},
      disconnect: {:erlang, :disconnect_node, []},
      list_nodes: {:erlang, :nodes, [:connected]}
    ]

    Keyword.put(topologies, :epmd, epmd)
  else
    topologies
  end

topologies =
  if System.get_env("CLUSTER_POSTGRES") == "true" && Application.spec(:supavisor, :vsn) do
    %Version{major: maj, minor: min} =
      Application.spec(:supavisor, :vsn) |> List.to_string() |> Version.parse!()

    region =
      (Enum.find_value(~W[CLUSTER_ID LOCATION_ID REGION], &System.get_env/1) || "local")
      |> String.replace("-", "_")

    postgres = [
      strategy: Cluster.Strategy.Postgres,
      config: [
        url: System.get_env("DATABASE_URL", "ecto://postgres:postgres@localhost:6432/postgres"),
        heartbeat_interval: 5_000,
        channel_name: "supavisor_#{region}_#{maj}_#{min}",
        socket_options: db_socket_options
      ]
    ]

    Keyword.put(topologies, :postgres, postgres)
  else
    topologies
  end

config :libcluster,
  debug: false,
  topologies: topologies

upstream_ca =
  if path = System.get_env("GLOBAL_UPSTREAM_CA_PATH") do
    File.read!(path)
    |> Supavisor.Helpers.cert_to_bin()
    |> case do
      {:ok, bin} ->
        Logger.info("Loaded upstream CA from $GLOBAL_UPSTREAM_CA_PATH",
          ansi_color: :green
        )

        bin

      {:error, _} ->
        raise "There is no valid certificate in $GLOBAL_UPSTREAM_CA_PATH"
    end
  end

downstream_cert =
  if path = System.get_env("GLOBAL_DOWNSTREAM_CERT_PATH") do
    if File.exists?(path) do
      Logger.info("Loaded downstream cert from $GLOBAL_DOWNSTREAM_CERT_PATH, path: #{path}",
        ansi_color: :green
      )

      path
    else
      raise "There is no such file in $GLOBAL_DOWNSTREAM_CERT_PATH"
    end
  end

downstream_key =
  if path = System.get_env("GLOBAL_DOWNSTREAM_KEY_PATH") do
    if File.exists?(path) do
      Logger.info("Loaded downstream key from $GLOBAL_DOWNSTREAM_KEY_PATH, path: #{path}",
        ansi_color: :green
      )

      path
    else
      raise "There is no such file in $GLOBAL_DOWNSTREAM_KEY_PATH"
    end
  end

downstream_ec_cert =
  if path = System.get_env("DOWNSTREAM_SERVER_ECDSA_CERT") do
    if File.exists?(path) do
      Logger.info(
        "Loaded downstream ECDSA cert from $DOWNSTREAM_SERVER_ECDSA_CERT, path: #{path}",
        ansi_color: :green
      )

      path
    else
      raise "There is no such file in $DOWNSTREAM_SERVER_ECDSA_CERT"
    end
  end

downstream_ec_key =
  if path = System.get_env("DOWNSTREAM_SERVER_ECDSA_KEY") do
    if File.exists?(path) do
      Logger.info(
        "Loaded downstream ECDSA key from $DOWNSTREAM_SERVER_ECDSA_KEY, path: #{path}",
        ansi_color: :green
      )

      path
    else
      raise "There is no such file in $DOWNSTREAM_SERVER_ECDSA_KEY"
    end
  end

if config_env() != :test do
  config :supavisor,
    session_proxy_ports:
      System.get_env("SESSION_PROXY_PORTS", "12100,12101,12102,12103")
      |> parse_integer_list.(),
    transaction_proxy_ports:
      System.get_env("TRANSACTION_PROXY_PORTS", "12104,12105,12106,12107")
      |> parse_integer_list.(),
    availability_zone: System.get_env("AVAILABILITY_ZONE"),
    region: System.get_env("REGION") || System.get_env("FLY_REGION") || "local",
    fly_alloc_id: System.get_env("FLY_ALLOC_ID"),
    jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}") |> JSON.decode!(),
    api_jwt_secret: System.get_env("API_JWT_SECRET", if(config_env() == :dev, do: "dev")),
    metrics_jwt_secret: System.get_env("METRICS_JWT_SECRET", if(config_env() == :dev, do: "dev")),
    proxy_port_transaction:
      System.get_env("PROXY_PORT_TRANSACTION", "6543") |> String.to_integer(),
    proxy_port_session:
      System.get_env("PROXY_PORT_SESSION", if(config_env() == :dev, do: "5452", else: "5432"))
      |> String.to_integer(),
    proxy_port: System.get_env("PROXY_PORT", "5412") |> String.to_integer(),
    prom_poll_rate: System.get_env("PROM_POLL_RATE", "15000") |> String.to_integer(),
    global_upstream_ca: upstream_ca,
    global_downstream_cert: downstream_cert,
    global_downstream_key: downstream_key,
    global_downstream_ec_cert: downstream_ec_cert,
    global_downstream_ec_key: downstream_ec_key,
    api_blocklist: System.get_env("API_TOKEN_BLOCKLIST", "") |> String.split(","),
    metrics_blocklist: System.get_env("METRICS_TOKEN_BLOCKLIST", "") |> String.split(","),
    cache_bypass_users:
      System.get_env("CACHE_BYPASS_USERS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1),
    no_warm_pool_users:
      System.get_env("NO_WARM_POOL_USERS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1),
    node_host: System.get_env("NODE_IP", "127.0.0.1")

  config :supavisor, Supavisor.FeatureFlag, %{
    "named_prepared_statements" =>
      Supavisor.Helpers.get_env_bool("NAMED_PREPARED_STATEMENTS_ENABLED", false)
  }

  config :supavisor, Supavisor.Repo,
    url:
      System.get_env(
        "DATABASE_URL",
        if(config_env() == :dev, do: "ecto://postgres:postgres@localhost:5432/supavisor_dev")
      ),
    pool_size: System.get_env("DB_POOL_SIZE", "25") |> String.to_integer(),
    ssl_opts: [
      verify: :verify_none
    ],
    parameters: [
      application_name: "supavisor_meta"
    ],
    socket_options: db_socket_options

  config :supavisor, Supavisor.Vault,
    ciphers: [
      default: {
        Cloak.Ciphers.AES.GCM,
        tag: "AES.GCM.V1",
        key:
          System.get_env(
            "VAULT_ENC_KEY",
            if(config_env() == :dev, do: "aHD8DZRdk2emnkdktFZRh3E9RNg4aOY7")
          )
      }
    ]
end

if path = System.get_env("SUPAVISOR_LOG_FILE_PATH") do
  config :logger, :default_handler,
    config: [
      file: to_charlist(path),
      file_check: 1000,
      max_no_files: 5,
      # 8 MiB as a max file size
      max_no_bytes: 8 * 1024 * 1024
    ]
end

if System.get_env("SUPAVISOR_LOG_FORMAT") == "json" do
  config :logger, :default_handler,
    formatter:
      {Supavisor.Logger.LogflareFormatter,
       %{
         # metadata: metadata,
         top_level: [:project],
         context: []
       }}
end

config :logger,
  backends: [:console]

if System.get_env("LOGS_ENGINE") == "logflare" do
  if !System.get_env("LOGFLARE_API_KEY") or !System.get_env("LOGFLARE_SOURCE_ID") do
    raise """
    Environment variable LOGFLARE_API_KEY or LOGFLARE_SOURCE_ID is missing.
    Check those variables or choose another LOGS_ENGINE.
    """
  end

  config :logger,
    backends: [LogflareLogger.HttpBackend]
end

# Workspace services store keys and model files outside the release directory.
service_data_dir = System.get_env("SERVICE_DATA_DIR", Path.expand("../var/services", __DIR__))
config :supavisor, :service_mail_key_dir, Path.join(service_data_dir, "mail-keys")

unless System.get_env("FASTEMBED_CACHE_DIR") || System.get_env("HF_HOME") do
  System.put_env("FASTEMBED_CACHE_DIR", Path.join(service_data_dir, "models"))
end

{:ok, service_smtp_address} =
  System.get_env("SERVICE_SMTP_BIND", "127.0.0.1")
  |> String.to_charlist()
  |> :inet.parse_address()

service_smtp_tls =
  case {System.get_env("SERVICE_SMTP_CERTFILE"), System.get_env("SERVICE_SMTP_KEYFILE")} do
    {cert, key} when is_binary(cert) and is_binary(key) ->
      [certfile: String.to_charlist(cert), keyfile: String.to_charlist(key)]

    _ ->
      []
  end

config :supavisor, :inbound_smtp,
  enabled:
    System.get_env("SERVICE_SMTP_ENABLED", if(config_env() == :dev, do: "true", else: "false")) ==
      "true",
  address: service_smtp_address,
  port: String.to_integer(System.get_env("SERVICE_SMTP_PORT", "2525")),
  hostname: System.get_env("SERVICE_SMTP_HOSTNAME", "localhost"),
  tls_options: service_smtp_tls

# Optional retention. Zero keeps messages until an administrator deletes them.
config :supavisor,
       :service_mail_retention_days,
       max(0, String.to_integer(System.get_env("SERVICE_MAIL_RETENTION_DAYS", "0")))

# Private disk storage for logical PostgreSQL backups.
config :supavisor, Supavisor.Backups,
  directory:
    Path.expand(System.get_env("BACKUP_DIRECTORY", Path.join(service_data_dir, "backups"))),
  node_id: System.get_env("BACKUP_NODE_ID", to_string(elem(:inet.gethostname(), 1))),
  pg_bin: System.get_env("BACKUP_PG_BIN"),
  max_bytes: String.to_integer(System.get_env("BACKUP_MAX_BYTES", "2147483648")),
  quota_bytes: String.to_integer(System.get_env("BACKUP_QUOTA_BYTES", "21474836480")),
  timeout_seconds: String.to_integer(System.get_env("BACKUP_TIMEOUT_SECONDS", "3600"))

config :supavisor, Supavisor.Services.Media, directory: Path.join(service_data_dir, "tmp")
