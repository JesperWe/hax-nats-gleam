import envoy
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/json
import gleam/result
import gleam/string
import json_types/clientconnect.{ClientConnect, client_connect_encoder}
import json_types/serverinfo.{
  type ServerInfo, server_info_decoder, server_info_encoder,
}
import mug

pub type BitArrayError {
  ToStringFailed
}

pub type ParseError {
  BitArrayError(BitArrayError)
  JsonDecodeError(json.DecodeError)
}

pub fn parse_server_info_json(
  result: Result(String, BitArrayError),
) -> Result(ServerInfo, ParseError) {
  case result {
    Ok(json) ->
      json.parse(from: json, using: server_info_decoder())
      |> result.map_error(JsonDecodeError)
    Error(err) -> Error(BitArrayError(err))
  }
}

pub fn main() {
  io.println("Nats Connect")

  let server_host = case envoy.get("NATS_HOST") {
    Ok(host) -> host
    Error(_) -> "localhost"
  }

  let server_port = case envoy.get("NATS_PORT") {
    Ok(port_str) -> {
      case int.parse(port_str) {
        Ok(port) -> port
        Error(_) -> 4222
      }
    }
    Error(_) -> 4222
  }

  io.println(
    "Connecting to NATS server at "
    <> server_host
    <> ":"
    <> string.inspect(server_port),
  )

  let socket = case
    mug.new(server_host, port: server_port)
    |> mug.timeout(milliseconds: 500)
    |> mug.connect()
  {
    Ok(socket) -> {
      io.println("Connected!")
      socket
    }
    Error(err) -> {
      io.println("NATS Connection failed: " <> string.inspect(err))
      io.println(
        "Make sure NATS server is running on "
        <> server_host
        <> ":"
        <> string.inspect(server_port),
      )
      panic as "Cannot continue without NATS connection"
    }
  }

  io.println(string.inspect(socket))

  let assert Ok(packet) = mug.receive(socket, timeout_milliseconds: 1000)
  io.println("Received: " <> string.inspect(bit_array.to_string(packet)))

  let assert Ok(info) =
    packet
    |> bit_array.to_string
    |> result.map(string.drop_start(_, 5))
    |> result.map_error(fn(_) { ToStringFailed })
    |> parse_server_info_json

  io.println(json.to_string(server_info_encoder(info)))

  let connect_json =
    ClientConnect(
      verbose: True,
      pedantic: False,
      tls_required: False,
      name: "hax-client",
      lang: "gleam",
      version: "0.1.0",
      protocol: 1,
      echo_enabled: True,
    )
    |> client_connect_encoder
    |> json.to_string

  let connect_command = "CONNECT " <> connect_json <> "\r\n"
  let assert Ok(_) = mug.send(socket, bit_array.from_string(connect_command))

  io.println("CONNECT message sent: " <> connect_command)
}
