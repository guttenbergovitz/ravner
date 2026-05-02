# Ravner

Domain and infrastructure inventory management system.

## Setup

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Engineering Standards

The project follows strict Elixir/Phoenix idiomatic patterns:

- **Strict Typing**: All public context functions must have `@spec` annotations. Core data structures are defined via `@type t`. Dialyzer is used for static analysis (`mix dialyzer`).
- **Code Quality**: Cyclomatic complexity is kept low. Credo is used to enforce style and refactoring standards (`mix credo --strict`).
- **Functional Pipelines**: Ecto queries and data transformations prefer composable functions and pattern matching over nested conditionals.
- **Documentation**: Professional `@moduledoc` and `@doc` annotations are required for onboarding both human developers and LLM-based agents.

## Development Tools

- `mix test` - Run the test suite (94+ tests)
- `mix credo --strict` - Run code quality analysis
- `mix dialyzer` - Run static type checking
- `mix format` - Enforce consistent code formatting

