#!lua name=voipbench
-- Redis 7+/8 function library - the FAIR Redis arm for every scenario.
-- Load: redis-cli FUNCTION LOAD REPLACE "$(cat voipbench.lua)"
-- Functions run atomically (single-threaded, no interleaving), exactly like a
-- non-yielding Tarantool memtx procedure.

-- scenario 0: transport floor
redis.register_function('noop', function(keys, args) return 1 end)

-- scenario 1, fair: per-caller ZSET (score = ts, member = CDR id). O(log N + M), 1 RTT.
-- KEYS[1] = cdr:src:<caller>   ARGV[1] = limit
redis.register_function{function_name = 'cdr_by_src', flags = {'no-writes'},
  callback = function(keys, args)
    local ids = redis.call('ZREVRANGE', keys[1], 0, tonumber(args[1]) - 1)
    return table.concat(ids, ',')
  end}

-- scenario 1, STRAWMAN (what the screenshots measured): scan one big list of JSON.
-- KEYS[1] = cdrs:all   ARGV[1] = caller  ARGV[2] = limit
redis.register_function{function_name = 'cdr_scan', flags = {'no-writes'},
  callback = function(keys, args)
    local all = redis.call('LRANGE', keys[1], 0, -1)
    local ids, lim = {}, tonumber(args[2])
    for i = #all, 1, -1 do
      local c = cjson.decode(all[i])
      if c.src == args[1] then
        ids[#ids + 1] = c.id
        if #ids >= lim then break end
      end
    end
    return table.concat(ids, ',')
  end}

-- scenario 3, fair: atomic LCR acquire, idempotent per Call-ID.
-- KEYS = resv, trunk:1:calls, trunk:2:calls, trunk:3:calls
-- ARGV = ci, lim1, lim2, lim3
redis.register_function('lcr_acquire', function(keys, args)
  local cur = redis.call('HGET', keys[1], args[1])
  if cur then return tonumber(cur) end
  for t = 1, 3 do
    if redis.call('SCARD', keys[t + 1]) < tonumber(args[t + 1]) then
      redis.call('SADD', keys[t + 1], args[1])
      redis.call('HSET', keys[1], args[1], t)
      return t
    end
  end
  return 0
end)

-- KEYS = resv, trunk:1:calls, trunk:2:calls, trunk:3:calls   ARGV = ci
redis.register_function('lcr_release', function(keys, args)
  local t = redis.call('HGET', keys[1], args[1])
  if not t then return 0 end
  redis.call('SREM', keys[tonumber(t) + 1], args[1])
  redis.call('HDEL', keys[1], args[1])
  return 1
end)
