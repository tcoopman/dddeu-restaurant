defmodule Restaurant.Queue do
    def start_link() do
        {:ok, message_queue} = Agent.start_link(fn -> 
            %{
                messages: :queue.new(),
                count: 0,
                processed: 0
            }
        end)
    end      

    def count(pid) do
        Agent.get(pid, fn %{count: count} -> count end)
    end

    def processed(pid) do
        Agent.get(pid, fn %{processed: processed} -> processed end)
    end

    def peek(pid) do
        Agent.get(pid, fn %{processed: processed} -> processed end)
    end

    def work(pid) do
        
    end
end