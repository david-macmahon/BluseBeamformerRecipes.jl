"""
    targets2bfr(redis, message, outdir, telinfo_file)

Subscriber worker function for Redis `target-selector:targets` channel.  This
function requires extra parameters beyond what the Redis `subscribe()` callback
supports.  It is expected that `subscribe()` will be passed a helper function
that will call this function with suitable parameters.

Messages published to the `target-selector:targets` channel have the format:

    targets:<telescope_name>:<subarray_name>:<timestamp>

This entire message is also the name of a Redis key that contains a JSON encoded
list of targets.  For each subscribed message, it performs these steps:

1. Parses targets `message` to extract the various components.
2. Gets a GuppiRaw.Header object by calling `subarray2grh()`
3. Retrieves the targets from Redis using key `targets:<telescope_name>`
3. Creates a BeamformerRecipe object
4. Outputs that object to an HDF5 file in `outdir` using the filename
   `<telescope_name>-<subarray_name>-<timestamp>.bfr5`.
"""
function targets2bfr(redis, message, outdir,
    telinfo_file::AbstractString=joinpath(ENV["HOME"], "telinfo.yml"))

    _, telescope_name, subarray_name, timestamp = split(message, ':')
    grh = subarray2grh(redis, subarray_name)
    if isempty(grh)
        @warn "no GUPPI RAW metadata found for subarray "
    beam_names, beam_positions = gettargets(redis, message)
    bfr = BeamformerRecipe(grh, beam_names, beam_positions; redis=redis, telinfo_file=telinfo_file)
    mkpath(outdir)
    bfrname = "$telescope_name-$subarray_name-$timestamp"
    to_hdf5(joinpath(outdir, bfrname), bfr)
end

"""
Retrieves a JSON encoded targets list from `redis` using `key`, parses it, and
returns `beam_names` and `beam_positions` Arrays suitable for passing to
`BeamformerRecipe`.
"""
function gettargets(redis, key)
    targets_json = get(redis, key)
    targets = YAML.load(targets_json)
    beam_names = getindex.(targets, "source_id")
    beam_positions = permutedims(getindex.(targets, ["ra" "dec"]))
    beam_names, beam_positions
end

# This is a long running function.  It never returns until interrupted by
# Ctrl-C.  It is intended to be invoked from the command line by:
#
# julia --project=DIR -e 'using BluseBeamformerRecipes; run_targets_listener()' OUTDIR [TELINFO_FILE]
function run_targets_listener(args...)
    if isempty(args)
        args = ARGS
        if isempty(args)
            error("no directory given")
        end
    end
    outdir = args[1]
    telinfo_file = get(args, 2, joinpath(ENV["HOME"], "telinfo.yml"))

    redishost = get(ENV, "REDISHOST", "redishost")
    redis = Redis.RedisConnection(host=redishost)
    sub = open_subscription(redis)

    subscribe(sub, "target-selector:targets", message->begin
        @info "got message" message
        try
            targets2bfr(redis, message, outdir, telinfo_file)
        catch e
            @error e _module=nothing _file=nothing
        end
    end)
    @info "subscribed to target-selector:targets"

    Base.exit_on_sigint(false)
    try
        while(true)
            sleep(1)
        end
    catch e
        e isa InterruptException || rethrow()
    finally
        disconnect(sub)
        disconnect(redis)
    end

    @info "done"
end