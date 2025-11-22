import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option}
import gleam/time/timestamp.{type Timestamp}

// Server type with id, capacity, assigned trip_ids, and last heartbeat
pub type Server {
  Server(
    id: String,
    capacity: Int,
    trip_ids: List(Int),
    heartbeat: Option(Timestamp),
  )
}

// HelloMessage type for incoming messages
pub type HelloMessage {
  HelloMessage(id: String, capacity: Int)
}

// ServerResponse type for outgoing messages with trip_ids
pub type ServerResponse {
  ServerResponse(id: String, trip_ids: List(Int))
}

pub type PositionsMessage {
  PositionsMessage(id: Int, vendor: Int, lat: Float, lng: Float)
}

pub fn positions_message_encoder(msg: PositionsMessage) -> json.Json {
  json.object([
    #("id", json.int(msg.id)),
    #("vendor", json.int(msg.vendor)),
    #("lat", json.float(msg.lat)),
    #("lng", json.float(msg.lng)),
  ])
}

// Decoder for HelloMessage (incoming JSON)
pub fn hello_message_decoder() -> decode.Decoder(HelloMessage) {
  use id <- decode.field("id", decode.string)
  use capacity <- decode.field("capacity", decode.int)
  decode.success(HelloMessage(id, capacity))
}

// Encoder for HelloMessage
pub fn hello_message_encoder(msg: HelloMessage) -> json.Json {
  json.object([
    #("id", json.string(msg.id)),
    #("capacity", json.int(msg.capacity)),
  ])
}

// Encoder for Server (if needed for responses)
pub fn server_encoder(server: Server) -> json.Json {
  json.object([
    #("id", json.string(server.id)),
    #("capacity", json.int(server.capacity)),
    #("trip_ids", json.array(server.trip_ids, json.int)),
  ])
}

// Encoder for ServerResponse
pub fn server_response_encoder(response: ServerResponse) -> json.Json {
  json.object([
    #("id", json.string(response.id)),
    #("trip_ids", json.array(response.trip_ids, json.int)),
  ])
}

pub fn server_response_decoder() -> decode.Decoder(ServerResponse) {
  use id <- decode.field("id", decode.string)
  use trip_ids <- decode.field("trip_ids", decode.list(decode.int))
  decode.success(ServerResponse(id, trip_ids))
}
