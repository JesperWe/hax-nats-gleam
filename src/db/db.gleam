import gleam/dynamic/decode
import sqlight
import gleam/result
import gleam/string

pub type TripsEntry {
  TripsEntry(id: Int, vendor: Int, lat: Float, lng: Float, timestamp: Float)
}

const sql_query_trips = "
SELECT id, vendor, lat, lng, timestamp
FROM trips
WHERE id = ?
"

pub fn get_trips_by_id(
  conn: sqlight.Connection,
  id: Int,
) -> Result(List(TripsEntry), String) {
  let trip_decoder = {
    use id <- decode.field(0, decode.int)
    use vendor <- decode.field(1, decode.int)
    use lat <- decode.field(2, decode.float)
    use lng <- decode.field(3, decode.float)
    use timestamp <- decode.field(4, decode.float)
    decode.success(TripsEntry(id, vendor, lat, lng, timestamp))
  }

  use trips <- result.try(
    sqlight.query(
      sql_query_trips,
      on: conn,
      with: [sqlight.int(id)],
      expecting: trip_decoder,
    )
    |> result.map_error(fn(err) { "Error getting trips: " <> string.inspect(err) }),
  )

  Ok(trips)
}
