# frozen_string_literal: true

module Fingerly
  class AgentSightings
    # One request worth reporting: its cache key, whether it was signed, and
    # the raw fields an {AgentSightingInput} is built from.
    #
    # @api private
    Sighting = Struct.new(:key, :signed, :fields, :bytes)

    # One pending report: the first sighting's fields and how many requests
    # it stands for.
    #
    # @api private
    Pending = Struct.new(:id, :key, :signed, :fields, :hits, :added_at, :bytes)

    # The server's answers, by key, least recently used first.
    #
    # Not thread-safe on its own: {AgentSightings} holds its lock around every
    # call.
    #
    # @api private
    class AnswerCache
      # @return [String, nil] the rules the entries were answered under
      attr_reader :rules_version

      def initialize(capacity)
        @capacity = capacity
        # A Hash keeps insertion order, so deleting and re-inserting a key on
        # every hit leaves the least recently used one first.
        @entries = {}
        @rules_version = nil
      end

      # @return [AgentSighting, nil] the answer, when present and unexpired
      def get(key, now)
        entry = @entries.delete(key)
        return nil if entry.nil? || entry[1] <= now

        @entries[key] = entry
        entry[0]
      end

      # Stores a response's answers. A new +rules_version+ drops every entry
      # first, and an answer with a ttl of 0 is never kept.
      #
      # @param answers [Array(String, AgentSighting)] keys and their answers
      def store(rules_version, answers, now)
        @entries.clear if @rules_version && @rules_version != rules_version
        @rules_version = rules_version
        answers.each do |key, answer|
          next unless answer.ttl.positive?

          @entries.delete(key)
          @entries[key] = [answer, now + answer.ttl]
          @entries.shift while @entries.size > @capacity
        end
      end

      def size = @entries.size
    end

    # Reports waiting to be sent, oldest first, bounded by item count.
    #
    # Unsigned sightings of one key fold into one item with a running count;
    # signed ones are never folded, each is its own item.
    #
    # @api private
    class PendingBuffer
      # @return [Integer] the estimated size of the pending items as JSON
      attr_reader :bytes

      def initialize(max_items, max_count)
        @max_items = max_items
        @max_count = max_count
        @items = {}
        @bytes = 0
        @sequence = 0
      end

      # @return [Symbol] +:folded+, +:added+ or +:dropped+ when full
      def add(sighting, now)
        unless sighting.signed
          existing = @items[sighting.key]
          if existing
            existing.hits = [existing.hits + 1, @max_count].min
            return :folded
          end
        end
        return :dropped if @items.size >= @max_items

        id = sighting.signed ? "#{sighting.key}/#{@sequence += 1}" : sighting.key
        insert(Pending.new(id, sighting.key, sighting.signed, sighting.fields, 1, now,
                           sighting.bytes))
        :added
      end

      # Removes and returns the oldest items, up to +max_items+ and
      # +max_bytes+, and always at least one.
      def take(max_items, max_bytes)
        batch = []
        size = 0
        @items.each_value do |item|
          break if batch.size >= max_items
          break if !batch.empty? && size + item.bytes > max_bytes

          batch << item
          size += item.bytes
        end
        batch.each { |item| @items.delete(item.id) }
        @bytes -= size
        batch
      end

      # Puts a batch that was not delivered back in front of everything
      # newer. A key counted again meanwhile takes the batch's count too.
      #
      # @return [Integer] items lost because the buffer was full
      def restore(batch)
        newer = @items
        @items = {}
        @bytes = 0
        room = @max_items - newer.size
        lost = 0
        batch.each do |item|
          later = item.signed ? nil : newer.delete(item.id)
          if later
            item.hits = [item.hits + later.hits, @max_count].min
          elsif room <= 0
            lost += 1
            next
          else
            room -= 1
          end
          insert(item)
        end
        newer.each_value { |item| insert(item) }
        lost
      end

      def size = @items.size

      def empty? = @items.empty?

      # @return [Numeric, nil] when the oldest pending item was added
      def oldest_at
        first = @items.first
        first && first[1].added_at
      end

      def clear
        @items.clear
        @bytes = 0
      end

      private

      def insert(item)
        @items[item.id] = item
        @bytes += item.bytes
      end
    end
  end
end
