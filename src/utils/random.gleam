import gleam/int
import gleam/list
import gleam/string

const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

pub fn random_string() -> String {
  let charset_length = string.length(charset)
  list.range(1, 32)
  |> list.map(fn(_) {
    let random_index = int.random(charset_length)
    string.slice(charset, random_index, 1)
  })
  |> string.join("")
}

pub fn random_int(min: Int, max: Int) -> Int {
  int.random(max - min + 1) + min
}