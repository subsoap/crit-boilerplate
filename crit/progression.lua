local progression = {}

local immediate_cancel_handlers = {}
local cleanup_handlers = {}
local late_cleanup_handlers = {}

local function run_cleanup_handlers(co)
  local handlers = cleanup_handlers[co]
  if handlers then
    for _, handler in pairs(handlers) do
      handler()
    end
    cleanup_handlers[co] = nil
  end
  local late_handlers = late_cleanup_handlers[co]
  if late_handlers then
    for _, handler in pairs(late_handlers) do
      handler()
    end
    late_cleanup_handlers[co] = nil
  end
end

function progression.create_detached(f)
  local co
  co = coroutine.create(function (...)
    f(...)
    run_cleanup_handlers(co)
  end)
  cleanup_handlers[co] = {}
  late_cleanup_handlers[co] = {}
  return co
end

function progression.detach(f, ...)
  local co = progression.create_detached(f)
  progression.resume(co, ...)
  return co
end

function progression.resume(co, ...)
  local result, cancel_handler = coroutine.resume(co, ...)
  if result then
    immediate_cancel_handlers[co] = cancel_handler
  else
    immediate_cancel_handlers[co] = nil
    print("ERROR: " .. debug.traceback(co, cancel_handler))
  end
end

local dead_coroutines = {}
setmetatable(dead_coroutines, { __mode = 'k' }) -- Weak table

function progression.cancel(co)
  local cancel_handler = immediate_cancel_handlers[co]
  if cancel_handler then
    cancel_handler()
    immediate_cancel_handlers[co] = nil
  end
  run_cleanup_handlers(co)
  dead_coroutines[co] = true
end

function progression.add_cleanup_handler(f, key, co, late)
  key = key or f
  co = co or coroutine.running()
  local handlers = (late and late_cleanup_handlers or cleanup_handlers)[co]
  if handlers then
    handlers[key] = f
  end
  return key
end

function progression.remove_cleanup_handler(key, co)
  co = co or coroutine.running()
  local handlers = cleanup_handlers[co]
  if handlers then
    handlers[key] = nil
  end
  local late_handlers = late_cleanup_handlers[co]
  if late_handlers then
    late_handlers[key] = nil
  end
  return key
end

-- Forking

local waiting_list = {}
setmetatable(waiting_list, { __mode = 'k' }) -- Weak table

local function wake_waiting_threads(co)
  local threads_waiting = waiting_list[co]
  if threads_waiting then
    for waiting_co in pairs(threads_waiting) do
      progression.resume(waiting_co)
    end
    waiting_list[co] = nil
  end
end

function progression.create_fork(f)
  local child
  local co = coroutine.running()
  child = progression.create_detached(f)

  -- When the parent terminates, the child gets cancelled
  progression.add_cleanup_handler(function ()
    progression.cancel(child)
  end, child, nil, true)

  -- When the child terminates, wake threads waiting on join() and the parent doesn't need to cancel it anymore
  progression.add_cleanup_handler(function ()
    progression.remove_cleanup_handler(child, co)
    wake_waiting_threads(child)
  end, nil, child, true)

  return child
end

function progression.fork(f, ...)
  local child = progression.create_fork(f)
  progression.resume(child, ...)
  return child
end

function progression.join(child)
  if dead_coroutines[child] or coroutine.status(child) == "dead" then
    return
  end
  local co = coroutine.running()
  local threads_waiting = waiting_list[child]
  if not threads_waiting then
    threads_waiting = {}
    waiting_list[child] = threads_waiting
  end
  threads_waiting[co] = true
  coroutine.yield(function ()
    local threads_waiting_ = waiting_list[child]
    if threads_waiting_ then
      threads_waiting_[co] = nil
    end
  end)
end

-- Message handling helpers

local default_message_predicate = function () return true end

-- predicate(message_id, message) => boolean
function progression.wait_for_message(message_id, predicate)
  message_id = hash(message_id)
  local co = coroutine.running()
  progression._subscribe_to_message(message_id, co, predicate or default_message_predicate)
  return coroutine.yield(function ()
    progression._unsubscribe_from_message(message_id, co)
  end)
end

-- Timers

function progression.wait(seconds)
  local co = coroutine.running()
  local sub_id = timer.delay(seconds, false, function ()
    progression.resume(co)
  end)
  coroutine.yield(function ()
    timer.cancel(sub_id)
  end)
end

-- Loadable functions

function progression.load_function(id)
  id = hash(id)
  local on_cancel = progression._load_function(id, coroutine.running())
  return coroutine.yield(on_cancel)
end

function progression.lazy_load_function(id)
  local f
  return function (...)
    if not f then
      f = progression.load_function(id)
    end
    return f(...)
  end
end

function progression.register_function(f)
  progression._loaded_function = f
end

function progression.init_register_function(f)
  _G.init = function ()
    progression.register_function(f)
  end
end

return progression