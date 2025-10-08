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

pub type ParseError {
  StringConversionError
  JsonDecodeError(json.DecodeError)
}

pub fn parse_server_info_json(
  json_string: String,
) -> Result(ServerInfo, json.DecodeError) {
  json.parse(from: json_string, using: server_info_decoder())
}

pub fn server_reply(packet: BitArray) -> Result(String, Nil) {
  bit_array.to_string(packet)
}

// Close the NATS connection gracefully
pub fn close_connection(socket: mug.Socket) -> Nil {
  io.println("Closing NATS connection...")
  case mug.shutdown(socket) {
    Ok(_) -> io.println("Connection closed successfully")
    Error(err) ->
      io.println("Error closing connection: " <> string.inspect(err))
  }
}

fn handle_ping(socket: mug.Socket) -> Nil {
  io.println("Received: PING")
  case mug.send(socket, bit_array.from_string("PONG\r\n")) {
    Ok(_) -> io.println("Sent: PONG")
    Error(err) -> io.println("Error sending PONG: " <> string.inspect(err))
  }
}

fn process_packet(socket: mug.Socket, packet: BitArray) -> Nil {
  case server_reply(packet) {
    Ok(reply) -> {
      case string.trim(reply) {
        "PING" -> handle_ping(socket)
        _ -> io.println("Message: " <> reply)
      }
    }
    Error(_) -> io.println("Error parsing message")
  }
}

pub fn receive_messages_loop(socket: mug.Socket) -> Nil {
  case mug.receive(socket, timeout_milliseconds: 1000) {
    Ok(packet) -> process_packet(socket, packet)
    Error(mug.Timeout) -> Nil
    // Timeout is normal, just continue
    Error(err) -> io.println("Error receiving message: " <> string.inspect(err))
  }
  receive_messages_loop(socket)
}

pub fn nats_server_connect(
  host: String,
  port: Int,
) -> Result(#(mug.Socket, ServerInfo), String) {
  // Create and connect socket
  use socket <- result.try(
    mug.new(host, port: port)
    |> mug.timeout(milliseconds: 500)
    |> mug.connect()
    |> result.map_error(fn(err) { "Connection failed: " <> string.inspect(err) }),
  )

  io.println("Connected!")

  // Receive initial INFO message
  use packet <- result.try(
    mug.receive(socket, timeout_milliseconds: 1000)
    |> result.map_error(fn(err) {
      close_connection(socket)
      "Failed to receive INFO message: " <> string.inspect(err)
    }),
  )

  // Convert packet to string
  use str <- result.try(
    bit_array.to_string(packet)
    |> result.map_error(fn(_) {
      close_connection(socket)
      "Failed to convert INFO packet to string"
    }),
  )

  // Parse INFO message (skip "INFO " prefix)
  use info <- result.try(
    json.parse(from: string.drop_start(str, 5), using: server_info_decoder())
    |> result.map_error(fn(err) {
      close_connection(socket)
      "Failed to parse server info: " <> string.inspect(err)
    }),
  )

  io.println("Received server info:")
  io.println(json.to_string(server_info_encoder(info)))

  // Send CONNECT message
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

  use _ <- result.try(
    mug.send(socket, bit_array.from_string(connect_command))
    |> result.map_error(fn(err) {
      close_connection(socket)
      "Failed to send CONNECT: " <> string.inspect(err)
    }),
  )

  io.println("Sent: CONNECT")

  // Receive response to CONNECT
  use response_packet <- result.try(
    mug.receive(socket, timeout_milliseconds: 1000)
    |> result.map_error(fn(err) {
      close_connection(socket)
      "Failed to receive CONNECT response: " <> string.inspect(err)
    }),
  )

  case server_reply(response_packet) {
    Ok(reply) -> io.println("Reply: " <> reply)
    Error(_) -> io.println("Error parsing reply")
  }

  Ok(#(socket, info))
}

pub fn run_nats_client(socket: mug.Socket) -> Result(Nil, mug.Error) {
  use _ <- result.try(mug.send(socket, bit_array.from_string("SUB > 1\r\n")))
  io.println("Sent: SUB >")

  use packet <- result.try(mug.receive(socket, timeout_milliseconds: 1000))
  case server_reply(packet) {
    Ok(reply) -> io.println("Reply: " <> reply)
    Error(_) -> io.println("Error parsing reply")
  }

  io.println("Waiting for messages... (Press Ctrl+C to stop)")
  receive_messages_loop(socket)

  Ok(Nil)
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

  // Connect to server and get initial INFO
  case nats_server_connect(server_host, server_port) {
    Error(err) -> {
      io.println("NATS Connection failed: " <> err)
      io.println(
        "Make sure NATS server is running on "
        <> server_host
        <> ":"
        <> string.inspect(server_port),
      )
      panic as "Cannot continue without NATS connection"
    }
    Ok(#(socket, _server_info)) -> {
      io.println(string.inspect(socket))

      // Run the NATS client with error handling
      case run_nats_client(socket) {
        Ok(_) -> {
          io.println("NATS client operations completed successfully")
          close_connection(socket)
        }
        Error(err) -> {
          io.println("Error during NATS operations: " <> string.inspect(err))
          close_connection(socket)
        }
      }
    }
  }
}
