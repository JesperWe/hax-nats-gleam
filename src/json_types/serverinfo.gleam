import gleam/dynamic/decode
import gleam/json

pub type ServerInfo {
  ServerInfo(
    server_id: String,
    server_name: String,
    version: String,
    proto: Int,
    go: String,
    host: String,
    port: Int,
    headers: Bool,
    max_payload: Int,
    client_id: Int,
    client_ip: String,
  )
}

pub fn server_info_decoder() -> decode.Decoder(ServerInfo) {
  use server_id <- decode.field("server_id", decode.string)
  use server_name <- decode.field("server_name", decode.string)
  use version <- decode.field("version", decode.string)
  use proto <- decode.field("proto", decode.int)
  use go <- decode.field("go", decode.string)
  use host <- decode.field("host", decode.string)
  use port <- decode.field("port", decode.int)
  use headers <- decode.field("headers", decode.bool)
  use max_payload <- decode.field("max_payload", decode.int)
  use client_id <- decode.field("client_id", decode.int)
  use client_ip <- decode.field("client_ip", decode.string)
  decode.success(ServerInfo(
    server_id,
    server_name,
    version,
    proto,
    go,
    host,
    port,
    headers,
    max_payload,
    client_id,
    client_ip,
  ))
}

pub fn server_info_encoder(info: ServerInfo) -> json.Json {
  json.object([
    #("server_id", json.string(info.server_id)),
    #("server_name", json.string(info.server_name)),
    #("version", json.string(info.version)),
    #("proto", json.int(info.proto)),
    #("go", json.string(info.go)),
    #("host", json.string(info.host)),
    #("port", json.int(info.port)),
    #("headers", json.bool(info.headers)),
    #("max_payload", json.int(info.max_payload)),
    #("client_id", json.int(info.client_id)),
    #("client_ip", json.string(info.client_ip)),
  ])
}
