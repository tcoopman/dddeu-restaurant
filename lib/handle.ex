alias Restaurant.{OrderPlaced, OrderCooked, OrderPriced, OrderPayed, FoodCookedTimedOut, GaveUp}
alias Restaurant.{CookOrder, PriceOrder, TakePayment, PublishIn, DuplicateMessage}
alias Restaurant.Order
alias Restaurant.Message.Context

defmodule Restaurant.AlarmClock do
    use GenServer

    def start_link() do
        GenServer.start_link(__MODULE__, nil, name: :alarm)
    end

    def handle_call(%PublishIn{timeout: timeout, message: message}, _from, state) do
        Process.send_after(self(), {:publish, message}, timeout)
        {:reply, nil, state}
    end

    def handle_info({:publish, message}, state) do
        Restaurant.PubSub.publish(message)
        {:noreply, state}
    end
end

defmodule Restaurant.Statistics do
    use GenServer

    def start_link() do
        GenServer.start_link(__MODULE__, nil, name: :stats)
    end

    def init(_) do
        schedule_work()
        {:ok, %{by_topic: %{}, by_correlation_id: %{}}}
    end

    def message_published(topic, msg = %{}) do
        GenServer.cast(:stats, {:message_published, topic, msg}) 
    end

    def message_published_by_correlation_id(_correlation_id, _msg = %{}) do
        # TODO
        # GenServer.cast(:stats, {:message_published_by_correlation_id, topic, msg}) 
    end

    def handle_cast({:message_published, topic, %{}}, state = %{}) do
        {_val, by_topic} = Map.get_and_update(state.by_topic, topic, fn item ->
            case item do
                nil -> {item, %{nb: 1}}
                _ -> {item, %{item | nb: item.nb + 1}}
            end
        end)

        {:noreply, %{state | by_topic: by_topic}}
    end

    def handle_info(:print, state) do
        IO.puts "STATS BY TOPIC:"
        Map.to_list(state.by_topic)
        |> Enum.each(fn {topic, stats} -> IO.puts "#{topic}: #{stats.nb}" end)
        schedule_work()
        {:noreply, state}
    end

    defp schedule_work() do
        Process.send_after(self(), :print, 5_000)
    end
end

defmodule Restaurant.ProcessManagerHouse do
    use GenServer

    @process_managers [Restaurant.ProcessManager.Normal, Restaurant.ProcessManager.PayFirst]

    def start_link() do
        GenServer.start_link(__MODULE__, %{})
    end

    def remove_correlation_id(pid, correlation_id) do
        GenServer.call(pid, {:remove_correlation_id, correlation_id})
    end

    def handle_call(message = %OrderPlaced{context: %Context{correlation_id: correlation_id}}, _from, state = %{}) do
        Restaurant.PubSub.subscribe(correlation_id, self())

        # TODO external random
        process_manager = Enum.random(@process_managers)

        {:ok, process_manager_pid} = process_manager.start_link(self())
        GenServer.call(process_manager_pid, message)
        new_state = Map.put(state, correlation_id, process_manager_pid)

        {:reply, nil, new_state}
    end
    def handle_call(message = %{context: %Context{correlation_id: correlation_id}}, _from, state = %{}) do
        process_manager_pid = Map.fetch!(state, correlation_id)

        GenServer.call(process_manager_pid, message)

        {:reply, nil, state}
    end
    def handle_call({:remove_correlation_id, correlation_id}, _from, state = %{}) do
        new_state = Map.delete(state, correlation_id)
        {:reply, nil, new_state}
    end
end

defmodule Restaurant.ProcessManager.Normal do
    use GenServer

    def start_link(house) do
        GenServer.start_link(__MODULE__, %{house: house, status: nil})
    end

    def handle_call(msg = %OrderPlaced{}, _from, state) do
        cook_order = %CookOrder{context: msg.context, message: msg.message}
        Restaurant.PubSub.publish(cook_order)
        timed_out = %FoodCookedTimedOut{message: cook_order, context: msg.context, retry: 1}
        Restaurant.PubSub.publish(%PublishIn{message: timed_out, context: msg.context, timeout: 1_000})
        {:reply, nil, state}
    end
    def handle_call(msg = %OrderCooked{}, _from, state) do
        if state.status == :done do
            Restaurant.PubSub.publish(%DuplicateMessage{context: msg.context, message: msg.message})
            {:reply, nil, state}
        else
            Restaurant.PubSub.publish(%PriceOrder{context: msg.context, message: msg.message})
            {:reply, nil, %{state | status: :done}}
        end
    end
    def handle_call(msg = %OrderPriced{}, _from, state) do
        Restaurant.PubSub.publish(%TakePayment{context: msg.context, message: msg.message})
        {:reply, nil, state}
    end
    def handle_call(msg = %FoodCookedTimedOut{retry: retry}, _from, state = %{status: status}) do
        cond do
            retry > 5 ->
                gave_up = %GaveUp{message: msg.message, context: msg.context}
                Restaurant.PubSub.publish(gave_up)
            true ->
                case status do
                    :done ->
                        :noop
                    _ ->
                        cook_order = msg.message
                        Restaurant.PubSub.publish(cook_order)
                        timed_out = %FoodCookedTimedOut{message: cook_order, context: msg.context, retry: msg.retry + 1}
                        Restaurant.PubSub.publish(%PublishIn{message: timed_out, context: msg.context, timeout: 1_000})
                end
        end

        {:reply, nil, state}
    end
    def handle_call(_, _from, state), do: {:reply, nil, state}
end
defmodule Restaurant.ProcessManager.PayFirst do
    use GenServer

    def start_link(house) do
        GenServer.start_link(__MODULE__, house)
    end

    def handle_call(msg = %OrderPlaced{}, _from, state) do
        Restaurant.PubSub.publish(%PriceOrder{context: msg.context, message: msg.message})
        {:reply, nil, state}
    end
    def handle_call(msg = %OrderPriced{}, _from, state) do
        Restaurant.PubSub.publish(%TakePayment{context: msg.context, message: msg.message})
        {:reply, nil, state}
    end
    def handle_call(msg = %OrderPayed{context: %Context{}}, _from, state) do
        cook_order = %CookOrder{context: msg.context, message: msg.message}
        Restaurant.PubSub.publish(cook_order)
        timed_out = %FoodCookedTimedOut{message: cook_order, context: msg.context, retry: 1}
        Restaurant.PubSub.publish(%PublishIn{message: timed_out, context: msg.context, timeout: 1_000})
        {:reply, nil, state}
    end
    def handle_call(msg = %FoodCookedTimedOut{}, _from, state = %{status: status}) do
        IO.puts "Received foodcookedtimeout"
        case status do
            :done ->
                {:reply, nil, state}
            _ ->
                cook_order = msg.message
                Restaurant.PubSub.publish(cook_order)
                timed_out = %FoodCookedTimedOut{message: cook_order, context: msg.context, retry: msg.retry + 1}
                Restaurant.PubSub.publish(%PublishIn{message: timed_out, context: msg.context, timeout: 1_000})

                {:reply, nil, state}
        end
    end
    def handle_call(_, _from, state), do: {:reply, nil, state}
end

defmodule Restaurant.PubSub do
    use GenServer

    def start_link() do
        GenServer.start_link(__MODULE__, %{topic_handlers: %{}, history: %{}}, name: :pubsub)
    end

    def subscribe(topic, handler) do
        GenServer.cast(:pubsub, {:subscribe, topic, handler})
    end

    def publish(message = %{context: %Context{correlation_id: correlation_id}}) do
        topic = message.__struct__
        GenServer.cast(:pubsub, {:publish, topic, message})
        GenServer.cast(:pubsub, {:publish, correlation_id, message})
        Restaurant.Statistics.message_published(topic, message)
        Restaurant.Statistics.message_published_by_correlation_id(correlation_id, message)
    end

    def get_history_for(topic) do
        GenServer.call(:pubsub, {:get_history_for, topic})
    end

    def handle_cast({:subscribe, topic, handler}, state = %{topic_handlers: topic_handlers}) do
        {_, new_topic_handlers} = Map.get_and_update(topic_handlers, topic, fn value ->
            case value do
                nil -> {value, [handler]}
                _ -> {value, [handler | value]}
            end
        end)
        {:noreply, %{state | topic_handlers: new_topic_handlers}}
    end

    def handle_cast({:publish, topic, message}, state = %{history: history}) do
        handlers = state.topic_handlers
        |> Map.get(topic, [])

        handlers
        |> Enum.each(fn handler -> 
            GenServer.call(handler, message) 
        end)

        {_, new_history} = Map.get_and_update(history, topic, fn value ->
            case value do
                nil -> {value, [message]}
                _ -> {value, [message | value]}
            end
        end)
        
        {:noreply, %{state | history: new_history}}
    end

    def handle_call({:get_history_for, topic}, _from, state = %{history: history}) do
        reply = Map.get(history, topic, [])
        {:reply, reply, state}
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
                    IO.puts "passing on"
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

    defp schedule_work(pid) do
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
                IO.puts "going on with it"
                GenServer.call(handler, message, 10_000)
            _ ->
                IO.puts "dropping message"
        end
        {:reply, nil, state}
    end
end

defmodule Restaurant.FuckUpMyMessages do
    use GenServer

    def start_link(handler) do
        GenServer.start_link(__MODULE__, %{handler: handler})
    end

    def handle_call(message = %{}, _from, state = %{handler: handler}) do
        should_i_fuck_up = :rand.normal
        cond do
            should_i_fuck_up > 0.8 -> 
                # duplicate
                IO.puts "Duplication"
                GenServer.call(handler, message, 10_000)
                GenServer.call(handler, message, 10_000)
            should_i_fuck_up > 0.6 -> 
                # delete
                IO.puts "Dropping"
                :noop
            true -> 
                IO.puts "normal cooking"
                IO.puts message.__struct__
                GenServer.call(handler, message, 10_000)
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
            # IO.puts "No empty handlers"
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
        new_order = place_order(table_number)
        Restaurant.PubSub.publish(new_order)
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

    def handle_call(%CookOrder{context: %Context{} = context, message: %Order{} = order}, _from, state = %{}) do
        IO.puts "I'm going to cook #{state.cook_name}"
        new_order = cook(order)
        new_message = %OrderCooked{context: Context.update(context), message: new_order}
        Restaurant.PubSub.publish(new_message)
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

    def handle_call(%PriceOrder{context: context, message: order}, _from, state) do
        new_order = priceMessage(order)
        new_message = %OrderPriced{context: Context.update(context), message: new_order}
        Restaurant.PubSub.publish(new_message)
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

    def handle_call(%TakePayment{context: context, message: order}, _from, state) do
        new_order = priceMessage(order)
        new_message = %OrderPayed{context: Context.update(context), message: new_order}
        Restaurant.PubSub.publish(new_message)
        {:reply, nil, state}
    end

    def priceMessage(%Order{} = order) do
        %{order | is_paid: true}
    end
end