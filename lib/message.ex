defmodule Restaurant.Order do
    defstruct [
        :table_number,
        :subTotal,
        :taxes,
        :total,
        :ingredients,
        :items,
        :is_paid,
    ]
end

defmodule Restaurant.Message.Context do
    alias Restaurant.Message.Context

    @enforce_keys [:id, :correlation_id, :causation_id, :created_on]
    defstruct [:id, :correlation_id, :causation_id, :created_on]

    def new do
        %Context{
            id: UUID.uuid4(),
            correlation_id: UUID.uuid4(),
            causation_id: :none,
            created_on: NaiveDateTime.utc_now()
        }
    end

    def update(previous = %Context{id: previous_id, correlation_id: correlation_id}) do
        %{ previous |
            id: UUID.uuid4(),
            correlation_id: correlation_id,
            causation_id: previous_id,
        }
    end
end

# Events
defmodule Restaurant.OrderPlaced do 
    @enforce_keys [:message, :context]
    defstruct [:message, :context]
end
defmodule Restaurant.OrderCooked do
    @enforce_keys [:message, :context]
    defstruct [:message, :context]
end
defmodule Restaurant.OrderPriced do
    @enforce_keys [:message, :context]
    defstruct [:message, :context]
end
defmodule Restaurant.OrderPayed do
    @enforce_keys [:message, :context]
    defstruct [:message, :context]
end

# Commands
defmodule Restaurant.CookOrder do
    @enforce_keys [:message, :context]
    defstruct [:message, :context]
end
defmodule Restaurant.PriceOrder do
    @enforce_keys [:message, :context]
    defstruct [:message, :context]
end
defmodule Restaurant.TakePayment do
    @enforce_keys [:message, :context]
    defstruct [:message, :context]
end