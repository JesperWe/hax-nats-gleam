import envoy
import gleam/int
import gleam/io
import gleam/result
import gleam/string
import nats.{close_connection, nats_server_connect, run_nats_client}

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

  io.println(
    "Connecting to NATS server at "
    <> server_host
    <> ":"
    <> string.inspect(server_port),
  )

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

  io.println(string.inspect(socket))

  // Run the NATS client with error handling
  case run_nats_client(socket) {
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
