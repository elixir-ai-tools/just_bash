defmodule JustBash.Parser.Lexer.Token do
  @moduledoc """
  Token representation for the bash lexer.

  Each token contains:
  - `type` - The token type (e.g., `:word`, `:pipe`, `:if`)
  - `value` - The string value of the token
  - `raw_value` - Original source text (for assignment parsing)
  - `start`/`end` - Byte positions in source
  - `line`/`column` - Line and column numbers
  - `quoted` - Whether the token started with a quote
  - `single_quoted` - Whether single-quoted specifically
  """

  defstruct [
    :type,
    :value,
    :raw_value,
    :start,
    :end,
    :line,
    :column,
    quoted: false,
    single_quoted: false
  ]

  @type token_type ::
          :eof
          | :newline
          | :semicolon
          | :amp
          | :pipe
          | :pipe_amp
          | :and_and
          | :or_or
          | :bang
          | :less
          | :great
          | :dless
          | :dgreat
          | :lessand
          | :greatand
          | :lessgreat
          | :dlessdash
          | :clobber
          | :tless
          | :and_great
          | :and_dgreat
          | :lparen
          | :rparen
          | :lbrace
          | :rbrace
          | :dsemi
          | :semi_and
          | :semi_semi_and
          | :dbrack_start
          | :dbrack_end
          | :dparen_start
          | :dparen_end
          | :if
          | :then
          | :else
          | :elif
          | :fi
          | :for
          | :while
          | :until
          | :do
          | :done
          | :case
          | :esac
          | :in
          | :function
          | :select
          | :time
          | :coproc
          | :word
          | :name
          | :number
          | :assignment_word
          | :comment
          | :heredoc_content

  @type t :: %__MODULE__{
          type: token_type(),
          value: String.t(),
          raw_value: String.t() | nil,
          start: non_neg_integer(),
          end: non_neg_integer(),
          line: pos_integer(),
          column: pos_integer(),
          quoted: boolean(),
          single_quoted: boolean()
        }

  @doc """
  Create a new token with the given attributes.
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Create an EOF token at the end of input.
  """
  @spec eof(String.t()) :: t()
  def eof(input) do
    {line, col} =
      input
      |> String.graphemes()
      |> Enum.reduce({1, 1}, fn
        "\n", {l, _} -> {l + 1, 1}
        _, {l, c} -> {l, c + 1}
      end)

    %__MODULE__{
      type: :eof,
      value: "",
      start: byte_size(input),
      end: byte_size(input),
      line: line,
      column: col
    }
  end
end
