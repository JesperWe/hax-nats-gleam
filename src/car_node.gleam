import car_actor/car_actor
import db/db
import envoy
import gleam/erlang/atom
import gleam/erlang/process.{call, sleep_forever, spawn}
import gleam/float
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import json_types/server.{HelloMessage, hello_message_encoder}
import nats.{
  type NATSMessage, close_connection, nats_send, nats_server_connect,
  nats_subscribe, run_nats_client,
}
import sqlight
import utils/random.{random_string}

const capacity_per_core = 5

const car_actor_timeout = 10

const tick_interval = 100

const heartbeat_interval = 1000

pub fn main() {
  // TODO: must send heartbeat

  let node_id = random_string()
  let capacity = get_capacity()

  let db_file = case envoy.get("DB_FILE") {
    Ok(host) -> host
    Error(_) -> panic as "DB_FILE is not set"
  }

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

  use #(socket, _server_info) <- result.try(
    nats_server_connect(server_host, server_port)
    |> result.map_error(fn(err) {
      io.println(
        "Make sure NATS server is running on "
        <> server_host
        <> ":"
        <> string.inspect(server_port),
      )

      panic as { "NATS connection failed: " <> err }
    }),
  )

  io.println("Connected to NATS")

  let nats_subject: process.Subject(NATSMessage) = process.new_subject()

  use Nil <- result.try(
    nats_subscribe(socket, "hello.response", 1)
    |> result.map_error(fn(err) {
      close_connection(socket)

      panic as {
        "Error subscribing to hello.response: " <> string.inspect(err)
      }
    }),
  )

  // Heartbeat loop
  spawn(fn() {
    loop(heartbeat_interval, fn() {
      case
        nats_send(socket, "PUB", "heartbeat " <> nats.to_nats_payload(node_id))
      {
        Ok(_) -> io.println("Heartbeat sent")
        Error(err) -> io.println("Error sending heartbeat: " <> err)
      }
    })
  })

  let _nats_client_loop = spawn(fn() { run_nats_client(socket, nats_subject) })

  io.println("Subscribed to hello.response")

  use Nil <- result.try(
    nats.nats_send(
      socket,
      "PUB",
      "hello "
        <> HelloMessage(node_id, capacity)
      |> hello_message_encoder
      |> json.to_string
      |> nats.to_nats_payload,
    )
    |> result.map_error(fn(err) {
      close_connection(socket)
      panic as { "Error sending hello message: " <> string.inspect(err) }
    }),
  )

  io.println("Waiting for car ids...")
  use car_ids <- result.try(
    get_car_ids_sync(nats_subject, node_id)
    |> result.map_error(fn(err) {
      close_connection(socket)
      panic as { "Failed to get car ids: " <> string.inspect(err) }
    }),
  )

  io.println("Got " <> int.to_string(list.length(car_ids)) <> " car ids")

  spawn(fn() {
    // Eat unused messages
    loop(0, fn() {
      process.receive_forever(nats_subject)
      Nil
    })
  })

  use conn <- sqlight.with_connection(db_file)

  io.println("Got connection to DB")

  io.println("Reading DB...")

  use #(start_timestamp, end_timestamp) <- result.try(
    case db.get_timestamp_interval(conn) {
      Ok(#(start_timestamp, end_timestamp)) if start_timestamp <. end_timestamp ->
        Ok(#(start_timestamp, end_timestamp))

      _ -> Error("Start timestamp must be less than end timestamp")
    }
    |> result.map_error(fn(err) {
      close_connection(socket)

      panic as { "Error getting timestamp interval: " <> string.inspect(err) }
    }),
  )

  io.println(
    "Read timestamp interval"
    <> string.inspect(#(start_timestamp, end_timestamp)),
  )

  io.println("Got " <> int.to_string(list.length(car_ids)) <> " car ids")

  let assert Ok(actors) =
    list.map(car_ids, fn(id) { car_actor.create(id, conn) })
    |> list.filter(fn(result) {
      case result {
        Ok(_) -> True
        Error(err) -> {
          io.println("Error creating actor for car " <> string.inspect(err))
          False
        }
      }
    })
    |> result.all

  let t0 = timestamp.system_time()

  let now = fn() -> Float {
    let seconds =
      timestamp.difference(t0, timestamp.system_time()) |> duration.to_seconds()

    let milliseconds = seconds *. 1000.0 /. 60.0 /. 2.5

    case
      float.modulo(
        start_timestamp +. milliseconds,
        by: end_timestamp -. start_timestamp,
      )
    {
      Ok(time) -> time
      Error(_) -> {
        close_connection(socket)
        panic as "Error moduloing timestamp"
      }
    }
  }

  // Tick loop
  spawn(fn() {
    loop(tick_interval, fn() {
      let time = now()
      io.println("----- Tick " <> string.inspect(time))

      actors
      |> list.each(fn(actor) {
        use response <- result.try(
          call(actor, car_actor_timeout, car_actor.Tick(time, _))
          |> result.map_error(fn(err) {
            // TODO: Maybe panic here, to let another node take over the cars
            // TODO: should be handled by supervision tree with restart strategy
            io.println("Error calling actor: " <> err)
          }),
        )

        case response {
          car_actor.Position(id, vendor, lat, lng) -> {
            case
              nats.nats_send(
                socket,
                "PUB",
                "positions "
                  <> server.PositionsMessage(id, vendor, lat, lng)
                |> server.positions_message_encoder
                |> json.to_string
                |> nats.to_nats_payload,
              )
            {
              Ok(_) -> io.println("Positions sent")
              Error(err) -> io.println("Error sending positions: " <> err)
            }
          }
          // TODO: do we need signal for inactive cars? Frontend can handle this probably.
          car_actor.Inactive(_id, _vendor) -> Nil
        }
        Ok(Nil)
      })
    })
  })

  sleep_forever()
  io.println("Exiting")
  Ok(Nil)
}

@external(erlang, "erlang", "system_info")
fn get_schedulers(atom: atom.Atom) -> Int

fn get_capacity() -> Int {
  capacity_per_core * get_schedulers(atom.create("schedulers"))
}

fn loop(interval: Int, callback: fn() -> Nil) -> Nil {
  callback()
  process.sleep(interval)
  loop(interval, callback)
}

// OBS: Hangs forever and consumes all NATS messages until hello.response with node_id is received
fn get_car_ids_sync(
  nats_subject: process.Subject(NATSMessage),
  node_id: String,
) -> Result(List(Int), String) {
  let msg = process.receive_forever(nats_subject)

  case json.parse(from: msg.payload, using: server.server_response_decoder()) {
    Ok(response) if response.id == node_id -> {
      io.println("Got car ids: " <> string.inspect(response.trip_ids))
      Ok(response.trip_ids)
    }
    _ -> {
      get_car_ids_sync(nats_subject, node_id)
    }
  }
}
