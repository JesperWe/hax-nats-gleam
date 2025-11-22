import envoy
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
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
  CheckHeartbeats
  RemoveStaleServers(stale_ids: List(String))
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

// Update the heartbeat timestamp for a server
fn update_server_heartbeat(
  servers: List(Server),
  server_id: String,
) -> List(Server) {
  let current_time = timestamp.system_time()
  list.map(servers, fn(server) {
    case server.id == server_id {
      True -> Server(..server, heartbeat: option.Some(current_time))
      False -> server
    }
  })
}

// Find servers with stale heartbeats (older than 2 seconds)
fn find_stale_servers(servers: List(Server)) -> List(String) {
  let current_time = timestamp.system_time()
  let two_seconds = duration.seconds(2)

  servers
  |> list.filter(fn(server) {
    case server.heartbeat {
      option.None -> True
      // No heartbeat yet, consider stale
      option.Some(last_heartbeat) -> {
        let time_since = timestamp.difference(last_heartbeat, current_time)
        duration.compare(time_since, two_seconds) == order.Gt
      }
    }
  })
  |> list.map(fn(server) { server.id })
}

// Remove servers by their IDs
fn remove_servers(
  servers: List(Server),
  ids_to_remove: List(String),
) -> List(Server) {
  list.filter(servers, fn(server) { !list.contains(ids_to_remove, server.id) })
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
                      heartbeat: option.Some(timestamp.system_time()),
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
            Error(_) -> {
              // Not a hello message, check if it's a heartbeat
              // Heartbeat messages are simple: just the server ID as plain text
              let server_id = string.trim(msg)

              // Check if this is a heartbeat from a known server
              case server_exists(state.servers, server_id) {
                True -> {
                  let updated_servers =
                    update_server_heartbeat(state.servers, server_id)
                  let new_state =
                    OrchestratorState(
                      servers: updated_servers,
                      socket: state.socket,
                    )
                  actor.continue(new_state)
                }
                False -> {
                  io.println("Unknown message or server: " <> msg)
                  actor.continue(state)
                }
              }
            }
          }
        }
      }
    }
    CheckHeartbeats -> {
      // Find servers with stale heartbeats
      let stale_ids = find_stale_servers(state.servers)
      case list.length(stale_ids) {
        0 -> actor.continue(state)
        _ -> {
          io.println("Removing stale servers: " <> string.join(stale_ids, ", "))
          let updated_servers = remove_servers(state.servers, stale_ids)
          let new_state =
            OrchestratorState(servers: updated_servers, socket: state.socket)
          io.println(
            "Remaining servers: " <> int.to_string(list.length(updated_servers)),
          )
          actor.continue(new_state)
        }
      }
    }
    RemoveStaleServers(stale_ids) -> {
      io.println("Removing stale servers: " <> string.join(stale_ids, ", "))
      let updated_servers = remove_servers(state.servers, stale_ids)
      let new_state =
        OrchestratorState(servers: updated_servers, socket: state.socket)
      io.println(
        "Remaining servers: " <> int.to_string(list.length(updated_servers)),
      )
      actor.continue(new_state)
    }
    Shutdown -> actor.stop()
  }
}

// Monitor function that checks heartbeats every second
fn heartbeat_monitor(actor_subject: Subject(Message)) -> Nil {
  // Sleep for 1 second
  process.sleep(1000)

  // Send CheckHeartbeats message to the main actor
  process.send(actor_subject, CheckHeartbeats)

  // Continue monitoring
  heartbeat_monitor(actor_subject)
}

// Bridge function to forward NATS messages to the actor
fn bridge_loop(
  nats_subject: Subject(NATSMessage),
  actor_subject: Subject(Message),
) -> Nil {
  // Receive a NATS message (blocks until one arrives)
  let nats_msg = process.receive_forever(nats_subject)
  // Extract the payload from NATSMessage and wrap it in our Message type
  case nats_msg {
    nats.NATSMessage(payload) -> {
      // Send the NATS payload to the actor wrapped in our NATS message type
      process.send(actor_subject, NATS(payload))
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
    Ok(_) -> io.println("Successfully subscribed to hello")
    Error(err) -> {
      io.println("Failed to subscribe to hello: " <> err)
      close_connection(socket)
      panic as "Cannot continue without subscription"
    }
  }

  // Subscribe to heartbeat messages
  case nats_subscribe(socket, "heartbeat", 2) {
    Ok(_) -> io.println("Successfully subscribed to heartbeat")
    Error(err) -> {
      io.println("Failed to subscribe to heartbeat: " <> err)
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

  // Start the heartbeat monitor
  io.println("Starting heartbeat monitor...")
  let _monitor =
    process.spawn(fn() {
      io.println("Heartbeat monitor started")
      heartbeat_monitor(actor.data)
    })

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
