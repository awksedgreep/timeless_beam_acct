# test/planes_test.exs writes to planes that are running, and is run when
# it is asked for: `mix test --only planes`.
ExUnit.start(exclude: [:planes])
