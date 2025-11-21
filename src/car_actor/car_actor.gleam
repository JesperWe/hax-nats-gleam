import db/db
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight

pub type TickResponse {
  Position(id: Int, vendor: Int, lat: Float, lng: Float)
  Inactive(id: Int, vendor: Int)
}

pub type Message(element) {
  Shutdown

  Tick(time: Float, reply_with: Subject(Result(TickResponse, String)))
}

pub fn create(
  id: Int,
  db_conn: sqlight.Connection,
) -> Result(process.Subject(Message(a)), String) {
  use trips <- result.try(
    db.get_trips_by_id(db_conn, id)
    |> result.map(fn(trips) {
      list.sort(trips, by: fn(a, b) { float.compare(a.timestamp, b.timestamp) })
    })
    |> result.map_error(fn(err) {
      "Error reading DB trips: " <> string.inspect(err)
    }),
  )

  use first_trip <- result.try(
    list.first(trips)
    |> result.map_error(fn(_) { "Expected non-empty list of trips" }),
  )

  let vendor = first_trip.vendor

  use started <- result.try(
    actor.new(State(id, vendor, trips))
    |> actor.on_message(handle_message)
    |> actor.start
    |> result.map_error(fn(err) {
      "Error starting actor: " <> string.inspect(err)
    }),
  )

  Ok(started.data)
}

type State {
  State(id: Int, vendor: Int, trips: List(db.TripsEntry))
}

fn handle_message(
  state: State,
  message: Message(e),
) -> actor.Next(State, Message(e)) {
  case message {
    Shutdown -> actor.stop()

    Tick(time, reply_with) -> {
      
      case interpolate_trip(state.trips, time) {
        Ok(#(lat, lng)) -> {
          process.send(reply_with, Ok(Position(state.id, state.vendor, lat, lng)))
        }
        Error(_) -> {
          process.send(reply_with, Ok(Inactive(state.id, state.vendor)))
        }
      }
      
      actor.continue(state)
  }
}

}
fn interpolate_trip(trips: List(db.TripsEntry), time: Float) -> Result(#(Float, Float), String) {
  case find_between(trips, time) {
    Ok(#(prev, next)) -> {

      let t = case next.timestamp -. prev.timestamp {
        0.0 -> 0.0
        t -> {time -. prev.timestamp} /. t
      }

      let lat = prev.lat +. t *. {next.lat -. prev.lat}
      let lng = prev.lng +. t *. {next.lng -. prev.lng}

      Ok(#(lat, lng))
    }

    Error(err) -> Error("Error interpolating trip: " <> err)
  }
}

fn find_between(
  items: List(db.TripsEntry),
  time: Float,
) -> Result(#(db.TripsEntry, db.TripsEntry), String) {
  case items {
    [] -> Error("Empty list")
    [_] -> Error("Need at least two items")
    [first, ..rest] -> find_between_help(first, rest, time)
  }
}

fn find_between_help(
  prev: db.TripsEntry,
  rest: List(db.TripsEntry),
  time: Float,
) -> Result(#(db.TripsEntry, db.TripsEntry), String) {
  case rest {
    [] -> Error("Time is beyond range")

    [next, ..tail] ->
      case time >=. prev.timestamp && time <=. next.timestamp {
        True -> Ok(#(prev, next))
        False -> find_between_help(next, tail, time)
      }
  }
}
