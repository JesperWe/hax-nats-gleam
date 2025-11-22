import gleam/dynamic/decode
import gleam/result
import gleam/string
import sqlight

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
    |> result.map_error(fn(err) {
      "Error getting trips: " <> string.inspect(err)
    }),
  )

  Ok(trips)
}

const sql_query_timestamp_interval = "
SELECT MIN(timestamp), MAX(timestamp)
FROM trips
"

pub fn get_timestamp_interval(
  conn: sqlight.Connection,
) -> Result(#(Float, Float), String) {
  let timestamp_decoder = {
    use start_timestamp <- decode.field(0, decode.float)
    use end_timestamp <- decode.field(1, decode.float)
    decode.success(#(start_timestamp, end_timestamp))
  }

  use results <- result.try(
    sqlight.query(
      sql_query_timestamp_interval,
      on: conn,
      with: [],
      expecting: timestamp_decoder,
    )
    |> result.map_error(fn(err) {
      "Error getting timestamp interval: " <> string.inspect(err)
    }),
  )

  case results {
    [interval] -> Ok(interval)
    [] -> Error("No timestamp data found")
    _ -> Error("Unexpected multiple rows returned")
  }
}
