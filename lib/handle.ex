alias Restaurant.{OrderPlaced, OrderCooked, OrderPriced, OrderPayed}
alias Restaurant.{CookOrder, PriceOrder, TakePayment}
alias Restaurant.Order
alias Restaurant.Message.Context

defmodule Restaurant.ProcessManagerHouse do
    use GenServer

    def start_link() do
        GenServer.start_link(__MODULE__, %{})
    end

    def handle_call(message = %OrderPlaced{context: %Context{correlation_id: correlation_id}}, _from, state = %{}) do
        IO.inspect "The house received the OrderPlaced"
        Restaurant.PubSub.subscribe(correlation_id, self())

        {:ok, process_manager_pid} = Restaurant.ProcessManager.start_link()
        IO.inspect "Forwardingn to"
        IO.inspect process_manager_pid
        GenServer.call(process_manager_pid, message)
        new_state = Map.put(state, correlation_id, process_manager_pid)

        {:reply, nil, new_state}
    end
    def handle_call(message = %{context: %Context{correlation_id: correlation_id}}, _from, state = %{}) do
        IO.inspect "The house is handling an other message"
        process_manager_pid = Map.fetch!(state, correlation_id)

        GenServer.call(process_manager_pid, message)

        {:reply, nil, state}
    end
end

defmodule Restaurant.ProcessManager do
    use GenServer

    def start_link() do
        GenServer.start_link(__MODULE__, nil)
    end

    def handle_call(msg = %OrderPlaced{}, _from, state) do
        IO.puts "Order placed in the ProcessManager"
        Restaurant.PubSub.publish(CookOrder, %CookOrder{context: msg.context, message: msg.message})
        {:reply, nil, state}
    end
    def handle_call(msg = %OrderCooked{}, _from, state) do
        IO.puts "Order Cooked in the ProcessManager"
        Restaurant.PubSub.publish(PriceOrder, %PriceOrder{context: msg.context, message: msg.message})
        {:reply, nil, state}
    end
    def handle_call(msg = %OrderPriced{}, _from, state) do
        Restaurant.PubSub.publish(TakePayment, %TakePayment{context: msg.context, message: msg.message})
        {:reply, nil, state}
    end
    def handle_call(msg = %OrderPayed{}, _from, state) do
        # TODO i'm done, remove me
        IO.puts "The order is payed"
        IO.inspect msg
        {:reply, nil, state}
    end
    def handle_call(msg, _from, state), do: {:reply, nil, state}
end

defmodule Restaurant.PubSub do
    use GenServer

    def start_link() do
        GenServer.start_link(__MODULE__, %{}, name: :pubsub)
    end

    def subscribe(topic, handler) do
        IO.puts "Subscribing #{topic}"
        GenServer.cast(:pubsub, {:subscribe, topic, handler})
    end

    def publish(topic, message = %{context: %Context{correlation_id: correlation_id}}) do
        IO.puts "Publishing #{topic}"
        GenServer.cast(:pubsub, {:publish, topic, message})
        IO.puts "Publishing #{correlation_id}"
        GenServer.cast(:pubsub, {:publish, correlation_id, message})
    end

    def handle_cast({:subscribe, topic, handler}, state = %{}) do
        {_, new_state} = Map.get_and_update(state, topic, fn value ->
            case value do
                nil -> {value, [handler]}
                _ -> {value, [handler | value]}
            end
        end)
        {:noreply, new_state}
    end

    def handle_cast({:publish, topic, message}, state = %{}) do
        state
        |> Map.get(topic, [])
        |> Enum.each(fn handler -> 
            IO.puts "calling after :publish"
            IO.inspect handler
            IO.inspect message
            GenServer.call(handler, message) 
        end)
        
        {:noreply, state}
    end
end

defmodule Restaurant.Threaded do
    use GenServer
    
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

    def handle_call(message = %{}, _from, state = %{message_queue: message_queue}) do
        Agent.update(message_queue, fn %{message_count: message_count, messages: messages} ->
            %{messages: :queue.in(message, messages), message_count: message_count + 1}
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
            queue_out = Agent.get(message_queue, fn %{messages: messages} ->
                :queue.out(messages) 
            end)
            case queue_out do
                {{:value, message}, new_queue} -> 
                    GenServer.call(handler, message)
                    Agent.update(message_queue, fn %{message_count: message_count} ->
                        %{messages: new_queue, message_count: message_count - 1}
                    end)
                {:empty, _} -> :noop
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

    def start_link(handler, ttl) do
        GenServer.start_link(__MODULE__, %{handler: handler, ttl: ttl})
    end

    def handle_call(message = %{context: %Context{created_on: created_on}}, _from, state = %{handler: handler, ttl: ttl}) do
        now = NaiveDateTime.utc_now()

        case NaiveDateTime.compare(now, NaiveDateTime.add(created_on, ttl, :millisecond)) do
            :lt ->
                GenServer.call(handler, message, 10_000)
            _ ->
                IO.puts "dropping message"
        end
        {:reply, nil, state}
    end
end

defmodule Restaurant.FairRoundRobin do
    use GenServer

    def start_link(handlers) do
        GenServer.start_link(__MODULE__, handlers)
    end

    def init(handlers) do
        state = %{handlers: handlers, messages: []}
        schedule_work()
        {:ok, state}
    end

    def handle_call(message = %{}, _from, %{handlers: handlers, messages: messages}) do
        {:reply, nil, %{handlers: handlers, messages: [message | messages]}}
    end

    def handle_info(:fill, state = %{handlers: handlers, messages: messages}) do
        maybe_handler = handlers
        |> Enum.find(fn handlerPid -> 
            Restaurant.Threaded.message_count(handlerPid) < 5
        end)

        new_state = if maybe_handler == nil do
            state
        else
            case messages do
                [message | tail] ->
                    GenServer.call(maybe_handler, message)
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

    def start_link(handlers) do
        queue = :queue.from_list(handlers)
        GenServer.start_link(__MODULE__, %{queue: queue})
    end

    def handle_call(message = %{}, _from, %{queue: queue}) do
        case :queue.out(queue) do
            {{:value, handler}, new_queue} -> 
                GenServer.call(handler, message)
                {:reply, nil, %{queue: :queue.in(handler, new_queue)}}
            {:empty, queue} -> {:reply, nil, %{queue: queue}}
        end 
    end
end

defmodule Restaurant.Waiter do
    use GenServer

    def start_link() do
        GenServer.start_link(__MODULE__, nil)
    end

    def order(pid, table_number) do
        GenServer.call(pid, table_number)
    end

    def handle_call(table_number, _from, state) do
        IO.puts "Waiter is working"
        new_order = place_order(table_number)
        Restaurant.PubSub.publish(OrderPlaced, new_order)
        {:reply, nil, state}
    end


    def place_order(table_number) do
        %OrderPlaced{ context: Context.new, message: %Order{ table_number: table_number}}
    end
end

defmodule Restaurant.Cook do
    use GenServer

    def start_link(cook_name) do
        state = %{cook_name: cook_name}
        GenServer.start_link(__MODULE__, state)
    end

    def handle_call(message = %CookOrder{context: %Context{} = context, message: %Order{} = order}, _from, state = %{cook_name: cook_name}) do
        IO.puts "#{cook_name} is cooking"
        new_order = cook(order)
        new_message = %OrderCooked{context: Context.update(context), message: new_order}
        Restaurant.PubSub.publish(OrderCooked, new_message)
        {:reply, nil, state}
    end

    def cook(%Order{} = order) do
        :timer.sleep(3000)
        %{order | ingredients: "Some ingredients"}
    end
end

defmodule Restaurant.Assistant do
    use GenServer

    def start_link() do
        GenServer.start_link(__MODULE__, nil)
    end

    def handle_call(message = %PriceOrder{context: context, message: order}, _from, state) do
        IO.puts "Assistant is working"
        new_order = priceMessage(order)
        new_message = %OrderPriced{context: Context.update(context), message: new_order}
        Restaurant.PubSub.publish(OrderPriced, new_message)
        {:reply, nil, state}
    end

    def priceMessage(%Order{} = order) do
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

    def start_link() do
        GenServer.start_link(__MODULE__, nil)
    end

    def handle_call(message = %TakePayment{context: context, message: order}, _from, state) do
        IO.puts "Cashier is working"
        new_order = priceMessage(order)
        new_message = %OrderPayed{context: Context.update(context), message: new_order}
        Restaurant.PubSub.publish(OrderPayed, new_message)
        {:reply, nil, state}
    end

    def priceMessage(%Order{} = order) do
        %{order | is_paid: true}
    end
end