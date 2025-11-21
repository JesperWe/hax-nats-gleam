import gleam/otp/actor
import gleam/erlang/process.{type Subject}
import gleam/string
import db/db
import sqlight
import gleam/list

pub type TickResponse {
  TickResponse(
    id: Int,
    vendor: Int,
    lat: Float,
    lng: Float,
  )
}

pub type Message(element) {
  Shutdown

  Tick(time: Int, reply_with: Subject(Result(TickResponse, Nil)))
}

pub fn create(id: Int, db_conn: sqlight.Connection) {
  let assert Ok(trips) = db.get_trips_by_id(db_conn, id)
  let assert Ok(first_trip) = list.first(trips)
  let vendor = first_trip.vendor

  actor.new(State(id, vendor, trips)) |> actor.on_message(handle_message) |> actor.start
}

type State {
  State(
    id: Int,
    vendor: Int,
    trips: List(db.TripsEntry),
  )
}

fn handle_message(
  state: State,
  message: Message(e),
) -> actor.Next(State, Message(e)) {
  case message {
    Shutdown -> actor.stop()

    Tick(time, reply_with) -> {
      echo "Tick " <> string.inspect(state.id) <> " " <> string.inspect(time)
      let assert Ok(first_trip) = list.first(state.trips)
      let lat = first_trip.lat
      let lng = first_trip.lng
      process.send(reply_with, Ok(TickResponse(state.id, state.vendor, lat, lng)))
      actor.continue(state)
    }
  }
}
