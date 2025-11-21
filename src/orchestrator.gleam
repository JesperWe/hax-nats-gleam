import envoy
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/otp/actor
import gleam/result
import gleam/string
import nats.{
  type NATSMessage, close_connection, nats_server_connect, nats_subscribe,
  run_nats_client,
}

pub type Message(element) {
  Shutdown
  NATS(msg: String)
}

fn handle_message(
  stack: List(e),
  message: Message(e),
) -> actor.Next(List(e), Message(e)) {
  case message {
    NATS(msg) -> {
      io.println("NATS message received: " <> msg)
      actor.continue(stack)
    }
    Shutdown -> actor.stop()
  }
}

// Bridge function to forward NATS messages to the actor
fn bridge_loop(
  nats_subject: Subject(NATSMessage),
  actor_subject: Subject(Message(a)),
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
    Ok(_) -> io.println("Successfully subscribed")
    Error(err) -> {
      io.println("Failed to subscribe: " <> err)
      close_connection(socket)
      panic as "Cannot continue without subscription"
    }
  }

  // Create a subject for NATS messages
  let nats_subject: Subject(NATSMessage) = process.new_subject()

  // Start the actor
  let assert Ok(actor) =
    actor.new([]) |> actor.on_message(handle_message) |> actor.start

  // Spawn a bridge process to forward NATS messages to the actor
  let _bridge = process.spawn(fn() { bridge_loop(nats_subject, actor.data) })

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
