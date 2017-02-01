defmodule Restaurant.Message do
    alias Restaurant.Message

    @enforce_keys [:id, :correlation_id, :causation_id, :created_on]
    defstruct [
        :id,
        :correlation_id,
        :causation_id,
        :table_number,
        :subTotal,
        :taxes,
        :total,
        :ingredients,
        :items,
        :is_paid,
        :created_on
    ]

    def new do
        %Message{
            id: UUID.uuid4(),
            correlation_id: UUID.uuid4(),
            causation_id: :none,
            created_on: NaiveDateTime.utc_now()
        }
    end
    
    def update(previous = %Message{id: previous_id, correlation_id: correlation_id}) do
        %{ previous |
            id: UUID.uuid4(),
            correlation_id: correlation_id,
            causation_id: previous_id,
        }
    end
end

defmodule Restaurant.Message.Item do
    defstruct [:name, :quantity, :price]
end

# Events
defmodule Restaurant.FoodOrdered do end
defmodule Restaurant.OrderCooked do end
defmodule Restaurant.OrderPriced do end
defmodule Restaurant.OrderPayed do end

# Commands
defmodule Restaurant.CookOrder do end
defmodule Restaurant.PriceOrder do end
defmodule Restaurant.TakePayment do end