import envoy
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import json_types/server.{
  type Server, Server, ServerResponse, hello_message_decoder,
  server_response_encoder,
}
import mug
import nats.{
  type NATSMessage, close_connection, nats_server_connect, nats_subscribe,
  run_nats_client,
}

const trips_count = 996

// State type for the orchestrator
pub type OrchestratorState {
  OrchestratorState(servers: List(Server), socket: mug.Socket)
}

pub type Message {
  Shutdown
  NATS(msg: String)
}

// Get all currently allocated trip IDs from all servers
fn get_allocated_trip_ids(servers: List(Server)) -> Set(Int) {
  servers
  |> list.flat_map(fn(s) { s.trip_ids })
  |> set.from_list
}

// Allocate trip IDs for a new server
fn allocate_trip_ids(servers: List(Server), capacity: Int) -> List(Int) {
  let allocated = get_allocated_trip_ids(servers)

  // Find free trip IDs from 0 to trips_count - 1
  let all_ids = list.range(0, trips_count - 1)
  let free_ids = list.filter(all_ids, fn(id) { !set.contains(allocated, id) })

  // Take up to 'capacity' free IDs
  list.take(free_ids, capacity)
}

// Find if a server with the given ID already exists
fn server_exists(servers: List(Server), id: String) -> Bool {
  list.any(servers, fn(s) { s.id == id })
}

fn handle_message(
  state: OrchestratorState,
  message: Message,
) -> actor.Next(OrchestratorState, Message) {
  case message {
    NATS(msg) -> {
      io.println("Actor NATS message received: " <> msg)

      // Ignore NATS protocol responses like +OK or -ERR
      case string.starts_with(msg, "+OK") || string.starts_with(msg, "-ERR") {
        True -> {
          io.println("NATS protocol response, ignoring")
          actor.continue(state)
        }
        False -> {
          // Try to decode the JSON message
          case json.parse(from: msg, using: hello_message_decoder()) {
            Ok(hello_msg) -> {
              io.println(
                "Decoded hello message - ID: "
                <> hello_msg.id
                <> ", Capacity: "
                <> int.to_string(hello_msg.capacity),
              )

              // Check if server already exists
              case server_exists(state.servers, hello_msg.id) {
                True -> {
                  io.println(
                    "Server " <> hello_msg.id <> " already exists, skipping",
                  )
                  actor.continue(state)
                }
                False -> {
                  // Allocate trip IDs for the new server
                  let allocated_ids =
                    allocate_trip_ids(state.servers, hello_msg.capacity)

                  // Create new server with allocated trip IDs
                  let new_server =
                    Server(
                      id: hello_msg.id,
                      capacity: hello_msg.capacity,
                      trip_ids: allocated_ids,
                    )

                  // Add to state
                  let new_servers = list.append(state.servers, [new_server])
                  let new_state =
                    OrchestratorState(
                      servers: new_servers,
                      socket: state.socket,
                    )

                  io.println(
                    "Added server "
                    <> hello_msg.id
                    <> " with "
                    <> int.to_string(list.length(allocated_ids))
                    <> " trip IDs allocated",
                  )
                  io.println(
                    "Total servers: " <> int.to_string(list.length(new_servers)),
                  )

                  // Create and send response with allocated trip IDs
                  let response =
                    ServerResponse(id: hello_msg.id, trip_ids: allocated_ids)
                  let response_json =
                    json.to_string(server_response_encoder(response))

                  // Send response back via NATS using PUB operation
                  // Format: PUB <subject> <size>\r\n<payload>
                  let subject = "hello.response"
                  let payload_size = string.byte_size(response_json)
                  let pub_command =
                    subject
                    <> " "
                    <> int.to_string(payload_size)
                    <> "\r\n"
                    <> response_json

                  case nats.nats_send(state.socket, "PUB", pub_command) {
                    Ok(_) -> io.println("Response sent: " <> response_json)
                    Error(err) -> io.println("Failed to send response: " <> err)
                  }

                  actor.continue(new_state)
                }
              }
            }
            Error(err) -> {
              io.println(
                "Failed to decode hello message: " <> string.inspect(err),
              )
              actor.continue(state)
            }
          }
        }
      }
    }
    Shutdown -> actor.stop()
  }
}

// Bridge function to forward NATS messages to the actor
fn bridge_loop(
  nats_subject: Subject(NATSMessage),
  actor_subject: Subject(Message),
) -> Nil {
  // Receive a NATS message (blocks until one arrives)
  io.println("Bridge: Waiting for NATS message...")
  let nats_msg = process.receive_forever(nats_subject)
  io.println("Bridge: Received NATS message!")
  // Extract the payload from NATSMessage and wrap it in our Message type
  case nats_msg {
    nats.NATSMessage(payload) -> {
      io.println("Bridge: Forwarding to actor: " <> payload)
      // Send the NATS payload to the actor wrapped in our NATS message type
      process.send(actor_subject, NATS(payload))
      io.println("Bridge: Message forwarded to actor")
    }
  }
  // Continue looping
  bridge_loop(nats_subject, actor_subject)
}

pub fn main() {
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

  // Connect to server and get initial INFO
  use #(socket, _server_info) <- result.try(
    nats_server_connect(server_host, server_port)
    |> result.map_error(fn(err) {
      io.println("NATS Connection failed: " <> err)
      io.println(
        "Make sure NATS server is running on "
        <> server_host
        <> ":"
        <> string.inspect(server_port),
      )
      panic as "Cannot continue without NATS connection"
    }),
  )

  case nats_subscribe(socket, "hello", 1) {
    Ok(_) -> io.println("Successfully subscribed")
    Error(err) -> {
      io.println("Failed to subscribe: " <> err)
      close_connection(socket)
      panic as "Cannot continue without subscription"
    }
  }

  // Start the actor with initial empty state and socket
  let initial_state = OrchestratorState(servers: [], socket: socket)
  let assert Ok(actor) =
    actor.new(initial_state) |> actor.on_message(handle_message) |> actor.start

  // Create a channel for the bridge process to send us its subject
  let bridge_subject_channel = process.new_subject()

  // Spawn a bridge process to forward NATS messages to the actor
  io.println("Starting bridge process...")
  let _bridge =
    process.spawn(fn() {
      io.println("Bridge process started")
      // Create the NATS subject in this process so we can receive on it
      let nats_subject: Subject(NATSMessage) = process.new_subject()
      // Send the subject back to the main process
      process.send(bridge_subject_channel, nats_subject)
      bridge_loop(nats_subject, actor.data)
    })

  // Wait for the bridge to send us its subject
  let nats_subject = process.receive_forever(bridge_subject_channel)

  case run_nats_client(socket, nats_subject) {
    Ok(_) -> {
      io.println("NATS client operations completed successfully")
      close_connection(socket)
      Ok(Nil)
    }
    Error(err) -> {
      io.println("Error during NATS operations: " <> string.inspect(err))
      close_connection(socket)
      Ok(Nil)
    }
  }
}
