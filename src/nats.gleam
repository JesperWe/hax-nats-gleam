import gleam/bit_array
import gleam/erlang/process.{type Subject}
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

// Message type for NATS messages sent to the actor
pub type NATSMessage {
  NATSMessage(payload: String)
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

// Send a NATS command with operation and payload
// Format: <operation> <size>\r\n<payload>\r\n
pub fn nats_send(
  socket: mug.Socket,
  operation: String,
  payload: String,
) -> Result(Nil, String) {
  let command = operation <> " " <> payload <> "\r\n"

  use _ <- result.try(
    mug.send(socket, bit_array.from_string(command))
    |> result.map_error(fn(err) {
      "Failed to send " <> operation <> ": " <> string.inspect(err)
    }),
  )

  Ok(Nil)
}

pub fn to_nats_payload(payload: String) -> String {
  int.to_string(string.byte_size(payload)) <> "\r\n" <> payload
}

fn handle_ping(socket: mug.Socket) -> Nil {
  case mug.send(socket, bit_array.from_string("PONG\r\n")) {
    Ok(_) -> Nil
    Error(err) -> io.println("Error sending PONG: " <> string.inspect(err))
  }
}

// Parse NATS MSG protocol: MSG <subject> <sid> <size>\r\n<payload>\r\n
fn parse_msg_payload(msg: String) -> Result(String, Nil) {
  case string.starts_with(msg, "MSG ") {
    True -> {
      // Split by newline to separate header from payload
      case string.split(msg, "\n") {
        [_header, payload, ..] -> {
          // Return the payload, trimming any trailing whitespace
          Ok(string.trim(payload))
        }
        _ -> Error(Nil)
      }
    }
    False -> Error(Nil)
  }
}

fn process_packet(
  socket: mug.Socket,
  packet: BitArray,
  actor: Subject(NATSMessage),
) -> Result(String, Nil) {
  case server_reply(packet) {
    Ok(reply) -> {
      case string.trim(reply) {
        "PING" -> {
          handle_ping(socket)
          Ok("PING > PONG")
        }
        _ -> {
          // Check if this is a MSG protocol message
          case parse_msg_payload(reply) {
            Ok(payload) -> {
              // Send only the payload to the actor
              process.send(actor, NATSMessage(payload))
              Ok(reply)
            }
            Error(_) -> {
              // Not a MSG, send the whole reply
              process.send(actor, NATSMessage(reply))
              Ok(reply)
            }
          }
        }
      }
    }
    Error(_) -> {
      io.println("Error parsing message")
      Error(Nil)
    }
  }
}

pub fn receive_messages_loop(
  socket: mug.Socket,
  actor: Subject(NATSMessage),
) -> Nil {
  case mug.receive(socket, timeout_milliseconds: 1000) {
    Ok(packet) -> {
      case process_packet(socket, packet, actor) {
        Ok(_) -> Nil
        Error(_) -> Nil
      }
      Nil
    }
    Error(mug.Timeout) -> Nil
    // Timeout is normal, just continue
    Error(err) -> Nil //io.println("Error receiving message: " <> string.inspect(err))
  }
  receive_messages_loop(socket, actor)
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

  use _ <- result.try(
    nats_send(socket, "CONNECT", connect_json)
    |> result.map_error(fn(err) {
      close_connection(socket)
      err
    }),
  )

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

pub fn nats_subscribe(
  socket: mug.Socket,
  subject: String,
  sid: Int,
) -> Result(Nil, String) {
  let sub_payload = subject <> " " <> string.inspect(sid)

  use _ <- result.try(nats_send(socket, "SUB", sub_payload))

  use packet <- result.try(
    mug.receive(socket, timeout_milliseconds: 1000)
    |> result.map_error(fn(err) {
      "Failed to receive SUB response: " <> string.inspect(err)
    }),
  )

  case server_reply(packet) {
    Ok(reply) -> {
      io.println("Reply: " <> reply)
      Ok(Nil)
    }
    Error(_) -> {
      io.println("Error parsing reply")
      Ok(Nil)
    }
  }
}

pub fn nats_unsubscribe(
  socket: mug.Socket,
  subject: String,
  sid: Int,
) -> Result(Nil, String) {
  let sub_payload = subject <> " " <> string.inspect(sid)

  use _ <- result.try(nats_send(socket, "UNSUB", sub_payload))

  use packet <- result.try(
    mug.receive(socket, timeout_milliseconds: 1000)
    |> result.map_error(fn(err) {
      "Failed to receive UNSUB response: " <> string.inspect(err)
    }),
  )

  case server_reply(packet) {
    Ok(reply) -> {
      io.println("Reply: " <> reply)
      Ok(Nil)
    }
    Error(_) -> {
      io.println("Error parsing reply")
      Ok(Nil)
    }
  }
}

pub fn run_nats_client(
  socket: mug.Socket,
  actor: Subject(NATSMessage),
) -> Result(Nil, mug.Error) {
  io.println("Waiting for messages... (Press Ctrl+C to stop)")
  receive_messages_loop(socket, actor)

  Ok(Nil)
}
