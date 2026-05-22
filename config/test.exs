import Config

config :bandera, start_on_boot: false

config :bandera, Bandera.TestRepo,
  database: Path.expand("../bandera_test.db", __DIR__),
  pool_size: 1

config :bandera, Bandera.Dashboard.TestEndpoint,
  url: [host: "localhost"],
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "banderatestlv"],
  pubsub_server: Bandera.Dashboard.TestPubSub,
  check_origin: false,
  server: false

config :phoenix, :json_library, Jason
