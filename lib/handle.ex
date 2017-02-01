defmodule Restaurant.PubSub do
    use GenServer


    def start_link() do
        GenServer.start_link(__MODULE__, %{}, name: :pubsub)
    end

    def subscribe(topic, handler) do
        IO.puts "Subscribing #{topic}"
        GenServer.call(:pubsub, {:subscribe, topic, handler})
    end

    def publish(topic, message) do
        IO.puts "Publishing #{topic}"
        GenServer.cast(:pubsub, {:publish, topic, message})
    end

    def handle_call({:subscribe, topic, handler}, _from, state = %{}) do
        {_, new_state} = Map.get_and_update(state, topic, fn value ->
            case value do
                nil -> {value, [handler]}
                _ -> {value, [handler | value]}
            end
        end)
        {:reply, nil, new_state}
    end

    def handle_cast({:publish, topic, message}, state = %{}) do
        state
        |> Map.get(topic, [])
        |> Enum.each(fn handler -> GenServer.call(handler, message) end)
        
        {:noreply, state}
    end
end
defmodule Restaurant.Printer do
    use GenServer

    alias Restaurant.Order

    def start_link() do
        GenServer.start_link(__MODULE__, nil)
    end

    def handle_call(order = %Order{}, _from, state) do
        IO.inspect order
        {:reply, nil, state}
    end
end

defmodule Restaurant.Threaded do
    use GenServer
    
    alias Restaurant.Order


    def start_link(handler) do
        GenServer.start_link(__MODULE__, handler)
    end

    def init(handler) do
        {:ok, message_queue} = Agent.start_link(fn -> %{messages: :queue.new(), message_count: 0} end)
        state = %{handler: handler, message_queue: message_queue}
        {:ok, state}
    end

    def message_count(pid) do
        GenServer.call(pid, :message_count)
    end

    def start(pid) do
        schedule_work(pid)
    end

    def handle_call(order = %Order{}, _from, state = %{message_queue: message_queue}) do
        IO.inspect "new threaded order"
        Agent.update(message_queue, fn %{message_count: message_count, messages: messages} ->
            %{messages: :queue.in(order, messages), message_count: message_count + 1}
        end)
        {:reply, nil, state}
    end

    def handle_call(:message_count, _from, state = %{message_queue: message_queue}) do
        message_count = Agent.get(message_queue, fn %{message_count: message_count} -> message_count end)
        {:reply, message_count, state}
    end

    def handle_info(:start, state = %{handler: handler, message_queue: message_queue}) do
        pid = self()
        spawn(fn ->
            queueOut = Agent.get(message_queue, fn %{messages: messages} ->
                :queue.out(messages) 
            end)
            case queueOut do
                {{:value, message}, new_queue} -> 
                    GenServer.call(handler, message)
                    Agent.update(message_queue, fn %{message_count: message_count} ->
                        %{messages: new_queue, message_count: message_count - 1}
                    end)
            end
            schedule_work(pid)
        end)
        {:noreply, state}
    end

    def schedule_work(pid) do
        Process.send_after(pid, :start, 1000)
    end
end

defmodule Restaurant.TimeToLive do
    use GenServer

    alias Restaurant.Order

    def start_link(handler, ttl) do
        GenServer.start_link(__MODULE__, %{handler: handler, ttl: ttl})
    end

    def handle_call(order = %Order{created_on: created_on}, _from, state = %{handler: handler, ttl: ttl}) do
        now = NaiveDateTime.utc_now()

        case NaiveDateTime.compare(now, NaiveDateTime.add(created_on, ttl, :millisecond)) do
            :lt ->
                GenServer.call(handler, order, 10000)
            _ ->
                IO.puts "dropping order"
        end
        {:reply, nil, state}
    end
end

defmodule Restaurant.FairRoundRobin do
    use GenServer

    alias Restaurant.Order

    def start_link(handlers) do
        GenServer.start_link(__MODULE__, handlers)
    end

    def init(handlers) do
        state = %{handlers: handlers, messages: []}
        schedule_work()
        {:ok, state}
    end

    def handle_call(order = %Order{}, _from, %{handlers: handlers, messages: messages}) do
        {:reply, nil, %{handlers: handlers, messages: [order | messages]}}
    end

    def handle_info(:fill, state = %{handlers: handlers, messages: messages}) do
        maybeHandler = handlers
        |> Enum.find(fn handlerPid -> 
            Restaurant.Threaded.message_count(handlerPid) < 5
        end)

        new_state = if maybeHandler == nil do
            state
        else
            case messages do
                [order | tail] ->
                    GenServer.call(maybeHandler, order)
                    %{handlers: handlers, messages: tail}
                _ -> state
            end
        end

        schedule_work()
        {:noreply, new_state}
    end

    defp schedule_work() do
        Process.send_after(self(), :fill, 1)
    end
end

defmodule Restaurant.RoundRobin do
    use GenServer

    alias Restaurant.Order

    def start_link(handlers) do
        queue = :queue.from_list(handlers)
        GenServer.start_link(__MODULE__, %{queue: queue})
    end

    def handle_call(order = %Order{}, _from, %{queue: queue}) do
        case :queue.out(queue) do
            {{:value, handler}, new_queue} -> 
                GenServer.call(handler, order)
                {:reply, nil, %{queue: :queue.in(handler, new_queue)}}
            {:empty, queue} -> {:reply, nil, %{queue: queue}}
        end 
    end
end

defmodule Restaurant.Waiter do
    use GenServer

    alias Restaurant.Order

    def start_link() do
        GenServer.start_link(__MODULE__, nil)
    end

    def order(pid, table_number) do
        GenServer.call(pid, table_number)
    end

    def handle_call(table_number, _from, state) do
        IO.puts "Waiter is working"
        new_order = place_order(table_number)
        Restaurant.PubSub.publish(:order_placed, new_order)
        {:reply, nil, state}
    end

    def place_order(table_number) do
        %Order{
            table_number: table_number,
            order_id: UUID.uuid4(),
            created_on: NaiveDateTime.utc_now()
        }
    end
end

defmodule Restaurant.Cook do
    use GenServer

    alias Restaurant.Order

    def start_link(cook_name) do
        state = %{cook_name: cook_name}
        GenServer.start_link(__MODULE__, state)
    end

    def handle_call(order = %Order{}, _from, state = %{cook_name: cook_name}) do
        IO.puts "#{cook_name} is cooking"
        new_order = cook(order)
        Restaurant.PubSub.publish(:order_cooked, new_order)
        {:reply, nil, state}
    end

    def cook(%Order{} = order) do
        :timer.sleep(3000)
        %{order | ingredients: "Some ingredients"}
    end
end

defmodule Restaurant.Assistant do
    use GenServer

    alias Restaurant.Order

    def start_link() do
        GenServer.start_link(__MODULE__, nil)
    end

    def handle_call(order = %Order{}, _from, state) do
        IO.puts "Assistant is working"
        new_order = priceOrder(order)
        Restaurant.PubSub.publish(:order_calculated, new_order)
        {:reply, nil, state}
    end

    def priceOrder(%Order{} = order) do
        :timer.sleep(1000)
        %{order | 
            subTotal: 5,
            taxes: 1.2,
            total: 6.2
        }
    end
end

defmodule Restaurant.Cashier do
    use GenServer

    alias Restaurant.Order

    def start_link() do
        GenServer.start_link(__MODULE__, nil)
    end

    def handle_call(order = %Order{}, _from, state) do
        IO.puts "Cashier is working"
        new_order = priceOrder(order)
        Restaurant.PubSub.publish(:order_paid, new_order)
        {:reply, nil, state}
    end

    def priceOrder(%Order{} = order) do
        %{order | is_paid: true}
    end
end