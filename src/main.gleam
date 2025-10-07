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

pub fn server_reply(packet: BitArray) -> Result(String, BitArrayError) {
  packet
  |> bit_array.to_string
  |> result.map_error(fn(_) { ToStringFailed })
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

// Continuously receive messages until interrupted
pub fn receive_messages_loop(socket: mug.Socket) -> Nil {
  case mug.receive(socket, timeout_milliseconds: 1000) {
    Ok(packet) -> {
      case server_reply(packet) {
        Ok(reply) -> {
          // Check if it's a PING message
          case string.trim(reply) {
            "PING" -> {
              io.println("Received: PING")
              // Send PONG reply
              case mug.send(socket, bit_array.from_string("PONG\r\n")) {
                Ok(_) -> io.println("Sent: PONG")
                Error(err) -> 
                  io.println("Error sending PONG: " <> string.inspect(err))
              }
              receive_messages_loop(socket)
            }
            _ -> {
              io.println("Message: " <> reply)
              receive_messages_loop(socket)
            }
          }
        }
        Error(_) -> {
          io.println("Error parsing message")
          receive_messages_loop(socket)
        }
      }
    }
    Error(mug.Timeout) -> {
      // Timeout is normal, just continue waiting
      receive_messages_loop(socket)
    }
    Error(err) -> {
      io.println("Error receiving message: " <> string.inspect(err))
      // Continue trying to receive messages
      receive_messages_loop(socket)
    }
  }
}

pub fn run_nats_client(socket: mug.Socket) -> Result(Nil, mug.Error) {
  // Receive server INFO
  use packet <- result.try(mug.receive(socket, timeout_milliseconds: 1000))

  let info_result =
    packet
    |> bit_array.to_string
    |> result.map(string.drop_start(_, 5))
    |> result.map_error(fn(_) { ToStringFailed })
    |> parse_server_info_json

  case info_result {
    Ok(info) -> io.println(json.to_string(server_info_encoder(info)))
    Error(err) ->
      io.println("Error parsing server info: " <> string.inspect(err))
  }

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
  use _ <- result.try(mug.send(socket, bit_array.from_string(connect_command)))
  io.println("Sent: CONNECT")

  use packet <- result.try(mug.receive(socket, timeout_milliseconds: 1000))
  case server_reply(packet) {
    Ok(reply) -> io.println("Reply: " <> reply)
    Error(_) -> io.println("Error parsing reply")
  }

  use _ <- result.try(mug.send(socket, bit_array.from_string("SUB > 1\r\n")))
  io.println("Sent: SUB >")

  use packet <- result.try(mug.receive(socket, timeout_milliseconds: 1000))
  case server_reply(packet) {
    Ok(reply) -> io.println("Reply: " <> reply)
    Error(_) -> io.println("Error parsing reply")
  }

  // Start receiving messages continuously
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
