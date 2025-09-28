import gleam/io
import gleam/string
import mug

pub fn main() {
  io.println("Nats Connect")

  let socket = case
    mug.new("localhost", port: 4222)
    |> mug.timeout(milliseconds: 500)
    |> mug.connect()
  {
    Ok(socket) -> socket
    _ -> panic as "Failed with error"
  }

  io.println(string.inspect(socket))

  let assert Ok(packet) = mug.receive(socket, timeout_milliseconds: 100)
  io.println(string.inspect(packet))

  packet
  // -> <<"Hello, Mike!":utf8>>
}
