defmodule Restaurant.Order do
    @enforce_keys [:order_id, :table_number, :created_on]
    defstruct [:order_id, :table_number, :subTotal, :taxes, :total, :ingredients, :items, :is_paid, :created_on]
end

defmodule Restaurant.Order.Item do
    defstruct [:name, :quantity, :price]
end