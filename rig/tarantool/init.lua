-- ndb_tarantool PR #4913 test rig - Tarantool side.
-- Run: tarantool init.lua   (env: TNT_PORT=3301, TNT_USER=kam, TNT_PASS=kampass,
--                             CDR_TSV=/data/cdr.tsv to preload the CDR set,
--                             TNT_WAL=none|write - match Redis persistence per cell)
local fiber = require('fiber')
local fio = require('fio')
local log = require('log')

box.cfg{
    listen = os.getenv('TNT_LISTEN') or tonumber(os.getenv('TNT_PORT') or 3301),
    memtx_memory = 1024 * 1024 * 1024,
    readahead = 1024 * 1024,
    log_level = 5,
    wal_mode = os.getenv('TNT_WAL') or 'none',
}

box.once('schema_v1', function()
    -- CDR store, scenario 1 (history lookup by caller)
    local cdr = box.schema.space.create('cdr', {format = {
        {name = 'id', type = 'unsigned'}, {name = 'src', type = 'string'},
        {name = 'dst', type = 'string'}, {name = 'ts', type = 'unsigned'},
        {name = 'dur', type = 'unsigned'}}})
    cdr:create_index('pk', {parts = {'id'}})
    cdr:create_index('by_src', {parts = {'src', 'ts'}, unique = false})

    -- Trunk limits + per-call reservations, scenario 3 (LCR with channel limits)
    local trunks = box.schema.space.create('trunks', {format = {
        {name = 'id', type = 'unsigned'}, {name = 'lim', type = 'unsigned'}}})
    trunks:create_index('pk', {parts = {'id'}})
    local resv = box.schema.space.create('resv', {format = {
        {name = 'ci', type = 'string'}, {name = 'trunk', type = 'unsigned'},
        {name = 'at', type = 'number'}}})
    resv:create_index('pk', {parts = {'ci'}})
    resv:create_index('by_trunk', {parts = {'trunk'}, unique = false})

    local user = os.getenv('TNT_USER') or 'kam'
    box.schema.user.create(user, {password = os.getenv('TNT_PASS') or 'kampass',
        if_not_exists = true})
    box.schema.user.grant(user, 'super', nil, nil, {if_not_exists = true})
end)

-- ---------------------------------------------------------------- data load
function cdr_load_tsv(path)
    local f = assert(io.open(path, 'r'))
    local n = 0
    box.begin()
    for line in f:lines() do
        local id, src, dst, ts, dur = line:match('^(%d+)\t(%S+)\t(%S+)\t(%d+)\t(%d+)$')
        box.space.cdr:replace{tonumber(id), src, dst, tonumber(ts), tonumber(dur)}
        n = n + 1
        -- yield per batch: Tarantool 3 aborts a fiber that runs > 1 s without yielding
        if n % 10000 == 0 then box.commit(); fiber.yield(); box.begin() end
    end
    box.commit()
    f:close()
    return n
end

function trunks_set(l1, l2, l3)
    box.space.trunks:replace{1, l1}
    box.space.trunks:replace{2, l2}
    box.space.trunks:replace{3, l3}
    box.space.resv:truncate()
    return true
end

-- ---------------------------------------------------------------- scenario 0: floor
function noop() return 1 end

-- ---------------------------------------------------------------- scenario 1: CDR
-- Newest `limit` CDR ids of a caller, comma-joined (same shape as the Redis arm).
function cdr_by_src(src, limit)
    limit = limit or 20
    local ids = {}
    for _, t in box.space.cdr.index.by_src:pairs({src}, {iterator = 'REQ'}) do
        ids[#ids + 1] = t.id
        if #ids >= limit then break end
    end
    return table.concat(ids, ',')
end

-- ---------------------------------------------------------------- scenario 3: LCR
-- Idempotent per Call-ID (INVITE retransmissions must not take a second channel).
-- No yield between count and insert, so memtx runs it atomically.
function lcr_acquire(ci)
    local r = box.space.resv:get(ci)
    if r then return r.trunk end
    for _, t in box.space.trunks:pairs() do
        if box.space.resv.index.by_trunk:count(t.id) < t.lim then
            box.space.resv:insert{ci, t.id, fiber.time()}
            return t.id
        end
    end
    return 0
end

-- POSITIVE CONTROL: same logic with a yield in the read-modify-write window.
-- Must produce violations; if it does not, the violation detector cannot fail.
function lcr_acquire_yield(ci)
    local r = box.space.resv:get(ci)
    if r then return r.trunk end
    for _, t in box.space.trunks:pairs() do
        if box.space.resv.index.by_trunk:count(t.id) < t.lim then
            fiber.sleep(0.001)
            box.space.resv:replace{ci, t.id, fiber.time()}
            return t.id
        end
    end
    return 0
end

function lcr_release(ci)
    box.space.resv:delete{ci}
    return 1
end

function lcr_inuse()
    local out = {}
    for _, t in box.space.trunks:pairs() do
        out[#out + 1] = box.space.resv.index.by_trunk:count(t.id)
    end
    return out
end

-- ---------------------------------------------------------------- fault procs
-- Return the arguments exactly as received, with their Lua types.
function echo(...)
    local out = {}
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        out[#out + 1] = {type(v), v}
    end
    return out
end
function slow(sec) fiber.sleep(sec); return 'late' end
function big(n) return string.rep('X', n) end
function fail() error('deliberate failure') end
function nothing() return nil end
function multi() return 1, 'two', {3} end

local tsv = os.getenv('CDR_TSV')
if tsv and fio.path.exists(tsv) and box.space.cdr:len() == 0 then
    log.info('loaded %d CDRs from %s', cdr_load_tsv(tsv), tsv)
end
trunks_set(15, 35, 50)
