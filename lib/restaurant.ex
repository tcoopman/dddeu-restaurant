defmodule Restaurant do
  @moduledoc """
  Documentation for Restaurant.
  """

  def create do
    {:ok, printer} = Restaurant.Printer.start_link()
    
    {:ok, cashier} = Restaurant.Cashier.start_link()

    {:ok, assistant} = Restaurant.Assistant.start_link()

    {:ok, cook_tom} = Restaurant.Cook.start_link("Tom")
    {:ok, cook_tom_ttl} = Restaurant.TimeToLive.start_link(cook_tom, 10000)
    {:ok, cook_tom_threaded} = Restaurant.Threaded.start_link(cook_tom_ttl)

    {:ok, cook_hank} = Restaurant.Cook.start_link("Hank")
    {:ok, cook_hank_ttl} = Restaurant.TimeToLive.start_link(cook_hank, 10000)
    {:ok, cook_hank_threaded} = Restaurant.Threaded.start_link(cook_hank_ttl)

    {:ok, cook_suzy} = Restaurant.Cook.start_link("Suzy")
    {:ok, cook_suzy_ttl} = Restaurant.TimeToLive.start_link(cook_suzy, 10000)
    {:ok, cook_suzy_threaded} = Restaurant.Threaded.start_link(cook_suzy_ttl)

    {:ok, kitchen} = Restaurant.FairRoundRobin.start_link([cook_tom_threaded, cook_hank_threaded, cook_suzy_threaded])
    {:ok, waiter} = Restaurant.Waiter.start_link()

    {:ok, _} = Restaurant.PubSub.start_link()
    Restaurant.PubSub.subscribe(:ordered, waiter)
    Restaurant.PubSub.subscribe(:cook_order, kitchen)
    Restaurant.PubSub.subscribe(:price_order, assistant)
    Restaurant.PubSub.subscribe(:take_payment, cashier)
    Restaurant.PubSub.subscribe(:order_payed, printer)

    Restaurant.Threaded.start(cook_tom_threaded)
    Restaurant.Threaded.start(cook_hank_threaded)
    Restaurant.Threaded.start(cook_suzy_threaded)
    
    waiter
  end

  def main do
    :observer.start()

    waiter = create()
    IO.puts "who is the waiter"
    IO.inspect waiter

    Enum.each(1..100, fn table_number ->
      IO.puts "ordering #{table_number}"
      Restaurant.Waiter.order(waiter, table_number)
      Process.sleep(50)
    end)

    IO.gets ""
  end
end
