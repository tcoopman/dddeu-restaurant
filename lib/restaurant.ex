defmodule Restaurant do
  @moduledoc """
  Documentation for Restaurant.
  """

  alias Restaurant.{OrderPlaced, CookOrder, PriceOrder, TakePayment, PublishIn}

  def create do
    {:ok, _} = Restaurant.PubSub.start_link()
    {:ok, _} = Restaurant.Statistics.start_link()
    {:ok, alarm} = Restaurant.AlarmClock.start_link()

    {:ok, cashier} = Restaurant.Cashier.start_link()

    {:ok, assistant} = Restaurant.Assistant.start_link()

    {:ok, cook_tom} = Restaurant.Cook.start_link("Tom")
    {:ok, drunken_tom} = Restaurant.FuckUpMyMessages.start_link(cook_tom)
    {:ok, cook_tom_ttl} = Restaurant.TimeToLive.start_link(drunken_tom, 10_000)
    {:ok, cook_tom_threaded} = Restaurant.Threaded.start_link(cook_tom_ttl)

    {:ok, cook_hank} = Restaurant.Cook.start_link("Hank")
    {:ok, drunken_hank} = Restaurant.FuckUpMyMessages.start_link(cook_hank)
    {:ok, cook_hank_ttl} = Restaurant.TimeToLive.start_link(drunken_hank, 10_000)
    {:ok, cook_hank_threaded} = Restaurant.Threaded.start_link(cook_hank_ttl)

    {:ok, cook_suzy} = Restaurant.Cook.start_link("Suzy")
    {:ok, drunken_suzy} = Restaurant.FuckUpMyMessages.start_link(cook_suzy)
    {:ok, cook_suzy_ttl} = Restaurant.TimeToLive.start_link(drunken_suzy, 10_000)
    {:ok, cook_suzy_threaded} = Restaurant.Threaded.start_link(cook_suzy_ttl)

    {:ok, kitchen} = Restaurant.FairRoundRobin.start_link([cook_tom_threaded, cook_hank_threaded, cook_suzy_threaded])
    {:ok, waiter} = Restaurant.Waiter.start_link()

    {:ok, process_manager_house} = Restaurant.ProcessManagerHouse.start_link()

    Restaurant.PubSub.subscribe(OrderPlaced, process_manager_house)
    Restaurant.PubSub.subscribe(PublishIn, alarm)

    Restaurant.PubSub.subscribe(CookOrder, kitchen)
    Restaurant.PubSub.subscribe(PriceOrder, assistant)
    Restaurant.PubSub.subscribe(TakePayment, cashier)

    Restaurant.Threaded.start(cook_tom_threaded)
    Restaurant.Threaded.start(cook_hank_threaded)
    Restaurant.Threaded.start(cook_suzy_threaded)

    
    waiter
  end

  def main do
    waiter = create()

    Enum.each(1..100, fn table_number ->
      Restaurant.Waiter.order(waiter, table_number)
      Process.sleep(50)
    end)
    Process.sleep(5000)

    IO.gets ""
  end
end
