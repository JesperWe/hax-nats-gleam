import gleam/dynamic/decode
import gleam/json

pub type ClientConnect {
  ClientConnect(
    verbose: Bool,
    pedantic: Bool,
    tls_required: Bool,
    name: String,
    lang: String,
    version: String,
    protocol: Int,
    echo_enabled: Bool,
  )
}

pub fn client_connect_decoder() -> decode.Decoder(ClientConnect) {
  use verbose <- decode.field("verbose", decode.bool)
  use pedantic <- decode.field("pedantic", decode.bool)
  use tls_required <- decode.field("tls_required", decode.bool)
  use name <- decode.field("name", decode.string)
  use lang <- decode.field("lang", decode.string)
  use version <- decode.field("version", decode.string)
  use protocol <- decode.field("protocol", decode.int)
  use echo_enabled <- decode.field("echo", decode.bool)
  decode.success(ClientConnect(
    verbose,
    pedantic,
    tls_required,
    name,
    lang,
    version,
    protocol,
    echo_enabled,
  ))
}

pub fn client_connect_encoder(connect: ClientConnect) -> json.Json {
  json.object([
    #("verbose", json.bool(connect.verbose)),
    #("pedantic", json.bool(connect.pedantic)),
    #("tls_required", json.bool(connect.tls_required)),
    #("name", json.string(connect.name)),
    #("lang", json.string(connect.lang)),
    #("version", json.string(connect.version)),
    #("protocol", json.int(connect.protocol)),
    #("echo", json.bool(connect.echo_enabled)),
  ])
}
