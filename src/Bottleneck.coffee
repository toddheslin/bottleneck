NUM_PRIORITIES = 10
DEFAULT_PRIORITY = 5
parser = require "./parser"
Local = require "./Local"
RedisStorage = require "./RedisStorage"
Events = require "./Events"
States = require "./States"
DLList = require "./DLList"
Sync = require "./Sync"
packagejson = require "../package.json"
class Bottleneck
  Bottleneck.default = Bottleneck
  Bottleneck.version = Bottleneck::version = packagejson.version
  Bottleneck.strategy = Bottleneck::strategy = { LEAK:1, OVERFLOW:2, OVERFLOW_PRIORITY:4, BLOCK:3 }
  Bottleneck.BottleneckError = Bottleneck::BottleneckError = require "./BottleneckError"
  Bottleneck.Group = Bottleneck::Group = require "./Group"
  jobDefaults:
    priority: DEFAULT_PRIORITY,
    weight: 1,
    expiration: null,
    id: "<no-id>"
  storeDefaults:
    maxConcurrent: null,
    minTime: 0,
    highWater: null,
    strategy: Bottleneck::strategy.LEAK,
    penalty: null,
    reservoir: null,
  storeInstanceDefaults:
    clientOptions: {},
    clearDatastore: false,
    Promise: Promise,
    _groupTimeout: null
  instanceDefaults:
    datastore: "local",
    id: "<no-id>",
    rejectOnDrop: true,
    trackDoneStatus: false,
    Promise: Promise
  constructor: (options={}, invalid...) ->
    unless options? and typeof options == "object" and invalid.length == 0
      throw new Bottleneck::BottleneckError "Bottleneck v2 takes a single object argument. Refer to https://github.com/SGrondin/bottleneck#upgrading-to-v2 if you're upgrading from Bottleneck v1."
    parser.load options, @instanceDefaults, @
    @_queues = @_makeQueues()
    @_scheduled = {}
    @_states = new States ["RECEIVED", "QUEUED", "RUNNING", "EXECUTING"].concat(if @trackDoneStatus then ["DONE"] else [])
    @_limiter = null
    @Events = new Events @
    @_submitLock = new Sync "submit"
    @_registerLock = new Sync "register"
    sDefaults = parser.load options, @storeDefaults, {}
    @_store = if @datastore == "local" then new Local parser.load options, @storeInstanceDefaults, sDefaults
    else if @datastore == "redis" then new RedisStorage @, sDefaults, parser.load options, @storeInstanceDefaults, {}
    else throw new Bottleneck::BottleneckError "Invalid datastore type: #{@datastore}"
  ready: => @_store.ready
  clients: => @_store.clients
  disconnect: (flush=true) => await @_store.disconnect flush
  chain: (@_limiter) => @
  queued: (priority) => if priority? then @_queues[priority].length else @_queues.reduce ((a, b) -> a+b.length), 0
  empty: -> @queued() == 0 and @_submitLock.isEmpty()
  running: => await @_store.__running__()
  jobStatus: (id) -> @_states.jobStatus id
  counts: -> @_states.statusCounts()
  _makeQueues: -> new DLList() for i in [1..NUM_PRIORITIES]
  _sanitizePriority: (priority) ->
    sProperty = if ~~priority != priority then DEFAULT_PRIORITY else priority
    if sProperty < 0 then 0 else if sProperty > NUM_PRIORITIES-1 then NUM_PRIORITIES-1 else sProperty
  _find: (arr, fn) -> (do -> for x, i in arr then if fn x then return x) ? []
  _getFirst: (arr) -> @_find arr, (x) -> x.length > 0
  _randomIndex: -> Math.random().toString(36).slice(2)
  check: (weight=1) => await @_store.__check__ weight
  _run: (next, wait, index) ->
    @Events.trigger "debug", ["Scheduling #{next.options.id}", { args: next.args, options: next.options }]
    done = false
    completed = (args...) =>
      if not done
        try
          done = true
          @_states.next next.options.id # DONE
          clearTimeout @_scheduled[index].expiration
          delete @_scheduled[index]
          @Events.trigger "debug", ["Completed #{next.options.id}", { args: next.args, options: next.options }]
          { running } = await @_store.__free__ index, next.options.weight
          @Events.trigger "debug", ["Freed #{next.options.id}", { args: next.args, options: next.options }]
          @_drainAll().catch (e) => @Events.trigger "error", [e]
          if running == 0 and @empty() then @Events.trigger "idle", []
          next.cb?.apply {}, args
        catch e
          @Events.trigger "error", [e]
    @_states.next next.options.id # RUNNING
    @_scheduled[index] =
      timeout: setTimeout =>
        @Events.trigger "debug", ["Executing #{next.options.id}", { args: next.args, options: next.options }]
        @_states.next next.options.id # EXECUTING
        if @_limiter? then @_limiter.submit.apply @_limiter, Array::concat next.options, next.task, next.args, completed
        else next.task.apply {}, next.args.concat completed
      , wait
      expiration: if next.options.expiration? then setTimeout =>
        completed new Bottleneck::BottleneckError "This job timed out after #{next.options.expiration} ms."
      , next.options.expiration
      job: next
  _drainOne: (freed) =>
    @_registerLock.schedule =>
      if @queued() == 0 then return @Promise.resolve false
      queue = @_getFirst @_queues
      { options, args } = queue.first()
      if freed? and options.weight > freed then return @Promise.resolve false
      @Events.trigger "debug", ["Draining #{options.id}", { args, options }]
      index = @_randomIndex()
      @_store.__register__ index, options.weight, options.expiration
      .then ({ success, wait, reservoir }) =>
        @Events.trigger "debug", ["Drained #{options.id}", { success, args, options }]
        if success
          next = queue.shift()
          empty = @empty()
          if empty then @Events.trigger "empty", []
          if reservoir == 0 then @Events.trigger "depleted", [empty]
          @_run next, wait, index
        @Promise.resolve success
  _drainAll: (freed) ->
    @_drainOne(freed)
    .then (success) =>
      if success then @_drainAll()
      else @Promise.resolve success
    .catch (e) => @Events.trigger "error", [e]
  _drop: (job) ->
    @_states.remove job.options.id
    if @rejectOnDrop then job.cb.apply {}, [new Bottleneck::BottleneckError("This job has been dropped by Bottleneck")]
    @Events.trigger "dropped", [job]
  submit: (args...) =>
    if typeof args[0] == "function"
      [task, args..., cb] = args
      options = @jobDefaults
    else
      [options, task, args..., cb] = args
      options = parser.load options, @jobDefaults
    job = { options, task, args, cb }
    options.priority = @_sanitizePriority options.priority
    if options.id == @jobDefaults.id then options.id = "#{options.id}-#{@_randomIndex()}"
    @_states.start options.id # RECEIVED

    @Events.trigger "debug", ["Queueing #{options.id}", { args, options }]
    @_submitLock.schedule =>
      try
        { reachedHWM, blocked, strategy } = await @_store.__submit__ @queued(), options.weight
        @Events.trigger "debug", ["Queued #{options.id}", { args, options, reachedHWM, blocked }]
      catch e
        @_states.remove options.id
        @Events.trigger "debug", ["Could not queue #{options.id}", { args, options, error: e }]
        job.cb e
        return false

      if blocked
        @_queues = @_makeQueues()
        @_drop job
        return true
      else if reachedHWM
        shifted = if strategy == Bottleneck::strategy.LEAK then @_getFirst(@_queues[options.priority..].reverse()).shift()
        else if strategy == Bottleneck::strategy.OVERFLOW_PRIORITY then @_getFirst(@_queues[(options.priority+1)..].reverse()).shift()
        else if strategy == Bottleneck::strategy.OVERFLOW then job
        if shifted? then @_drop shifted
        if not shifted? or strategy == Bottleneck::strategy.OVERFLOW
          if not shifted? then @_drop job
          return reachedHWM

      @_states.next job.options.id # QUEUED
      @_queues[options.priority].push job
      await @_drainAll()
      reachedHWM
  schedule: (args...) =>
    if typeof args[0] == "function"
      [task, args...] = args
      options = @jobDefaults
    else
      [options, task, args...] = args
      options = parser.load options, @jobDefaults
    wrapped = (args..., cb) ->
      returned = task.apply {}, args
      unless returned.then? then return cb new Bottleneck::BottleneckError "The function given to `schedule()` did not return a Promise. You may need to return `Promise.resolve(data)`. You returned: #{returned} (#{typeof returned})"
      returned
      .then (args...) -> cb.apply {}, Array::concat null, args
      .catch (args...) -> cb.apply {}, args
    new @Promise (resolve, reject) =>
      @submit.apply {}, Array::concat options, wrapped, args, (args...) ->
        (if args[0]? then reject else args.shift(); resolve).apply {}, args
      .catch (e) => @Events.trigger "error", [e]
  wrap: (fn) => (args...) => @schedule.apply {}, Array::concat fn, args
  updateSettings: (options={}) =>
    await @_store.__updateSettings__ parser.overwrite options, @storeDefaults
    parser.overwrite options, @instanceDefaults, @
    @_drainAll().catch (e) => @Events.trigger "error", [e]
    @
  currentReservoir: => await @_store.__currentReservoir__()
  incrementReservoir: (incr=0) =>
    await @_store.__incrementReservoir__ incr
    @_drainAll().catch (e) => @Events.trigger "error", [e]
    @

module.exports = Bottleneck
