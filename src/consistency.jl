# Consistency checks for the metadata used to build BeamformerRecipes.
#
# Background: on 2026-11-24 the BFR5 generator silently emitted 62-antenna
# recipes for a 55-antenna session because every input it used (the GuppiRaw
# header of the first allocated host/instance and the "latest" cal solution)
# was a stale leftover of the previous 62-antenna configuration, and the two
# stale inputs agreed with each other.  Half the fleet then failed loudly
# (raw header 55 vs recipe 62) while the other half silently produced
# products from the wrong antenna set (62 vs 62).  The checks below refuse
# to emit a recipe when its inputs disagree, converting silent data
# corruption into a loud failure.

using Dates

"""
    RecipeConsistencyError

Exception thrown when metadata consistency checks fail and a BeamformerRecipe
cannot be produced safely.  `run_targets_listener` catches this to publish a
Slack alert; the recipe for that scan is simply not emitted, so downstream
seticore jobs fail loudly (`could not open file ...bfr5`) instead of
processing data with mismatched metadata.
"""
struct RecipeConsistencyError <: Exception
    msg::String
end

Base.showerror(io::IO, e::RecipeConsistencyError) =
    print(io, "RecipeConsistencyError: ", e.msg)

# Slack pathway, mirroring the coordinator's redis_util.alert() message
# format so the existing slack_proxy picks these up unchanged.
const SLACK_CHANNEL = "meerkat-obs-log"
const SLACK_PROXY_CHANNEL = "slack-messages"

"Timestamp in the same format as the coordinator's `redis_util.timestring()`."
timestring() = Libc.strftime("%Y-%m-%d %H:%M:%S %Z", time())

"""
    slack_alert(redis, message; name="bfr5_generator",
                slack_channel=SLACK_CHANNEL, slack_proxy_channel=SLACK_PROXY_CHANNEL)

Publish `message` to Slack via the shared Redis slack-proxy channel, using
the same `"<channel>:[<timestring> - <name>] <message>"` format as the
coordinator's `redis_util.alert`.
"""
function slack_alert(redis, message; name="bfr5_generator",
                     slack_channel=SLACK_CHANNEL,
                     slack_proxy_channel=SLACK_PROXY_CHANNEL)
    publish(redis, slack_proxy_channel,
            "$slack_channel:[$(timestring()) - $name] $message")
end

"Format a value=>count dictionary as e.g. `55 (n=30), 62 (n=34)`."
function value_histogram(counts::Dict{<:Any,Int})
    join(("$v (n=$(counts[v]))" for v in sort!(collect(keys(counts)))), ", ")
end

"""
    check_nants(grh_nants, cal_nants, calkey)

Check that the antenna count in the GuppiRaw header agrees with the antenna
count of the cal solution selected for the scan.  Throws
`RecipeConsistencyError` on mismatch.
"""
function check_nants(grh_nants, cal_nants, calkey)
    grh_nants == cal_nants || throw(RecipeConsistencyError(
        "nant mismatch: raw header says $grh_nants antennas " *
        "but cal solution $calkey says $cal_nants"))
    return
end

"""
    check_antenna_names(subarray_name, cal_ants, antennas_list)

Check the cal solution's antenna names against the subarray's antenna list
(`\$subarray_name:antennas` in redis, pushed by the katcp server directly at
every configure and therefore not subject to the per-node pub/sub races that
can leave status hashes stale).  An empty `antennas_list` (missing key, e.g.
when reprocessing old data) skips the check with a warning.  Throws
`RecipeConsistencyError` on any disagreement in the antenna set.
"""
function check_antenna_names(subarray_name, cal_ants, antennas_list)
    if isempty(antennas_list)
        @warn "no antenna list found at redis key \"$subarray_name:antennas\", " *
              "skipping antenna-name consistency check" _module=nothing _file=nothing
        return
    end
    cal_set = Set(String.(cal_ants))
    list_set = Set(String.(antennas_list))
    cal_set == list_set && return
    diff = sort!(collect(symdiff(cal_set, list_set)))
    throw(RecipeConsistencyError(
        "antenna set mismatch for $subarray_name: cal solution has " *
        "$(length(cal_ants)) antennas but $subarray_name:antennas has " *
        "$(length(antennas_list)); difference ($(length(diff)) antennas): " *
        "$(join(diff, ","))"))
    return
end

"""
    subarray_nants(redis, hostinsts; domain="bluse") -> Dict{String,Int}

Collect the NANTS field from the status hash (`\$domain://\$hostinst/status`)
of each host/instance.  Hostinsts with no status hash or an unparseable NANTS
value are omitted (with a warning).
"""
function subarray_nants(redis, hostinsts; domain="bluse")
    nants_map = Dict{String,Int}()
    for hi in hostinsts
        v = hget(redis, "$domain://$hi/status", "NANTS")
        v === nothing && continue
        n = tryparse(Int, strip(v))
        if n === nothing
            @warn "unparseable NANTS value \"$v\" for $domain://$hi/status, " *
                  "excluding it from the NANTS consensus check" _module=nothing _file=nothing
            continue
        end
        nants_map[String(hi)] = n
    end
    nants_map
end

"""
    assert_nants_consensus(nants_map, subarray)

Verify that all host/instances report the same NANTS value.  On disagreement,
dump the per-hostinst values to stderr and throw `RecipeConsistencyError`
with a terse summary.  Note: no majority vote -- a stale majority is exactly
the failure mode this guards against (on 2026-11-24 the stale nodes were 34
of 64).
"""
function assert_nants_consensus(nants_map, subarray)
    length(nants_map) <= 1 && return
    vals = unique(collect(values(nants_map)))
    length(vals) <= 1 && return
    counts = Dict(v => count(==(v), values(nants_map)) for v in vals)
    @error "NANTS disagreement between hostinsts, per-hostinst values" subarray
    for hi in sort!(collect(keys(nants_map)))
        println(stderr, "  $hi: $(nants_map[hi])")
    end
    throw(RecipeConsistencyError(
        "NANTS disagreement across $(length(nants_map)) hostinsts for " *
        "$subarray: $(value_histogram(counts))"))
    return
end

"""
    check_scan_timestamp(starttime, message; tol=120.0)

Check the scan start time (unix seconds, computed from the GuppiRaw header)
against the timestamp embedded in the targets message
(`targets:<telescope>:<subarray>:<YYYYMMDDTHHMMSSZ>`).  The message timestamp
comes from the target selector and is independent of the per-node status
hashes the header was built from, so a large disagreement indicates a stale
header (e.g. a PKTSTART/SYNCTIME combination hours old, which also mis-selects
the cal solution).  Throws `RecipeConsistencyError` if the two differ by more
than `tol` seconds.  Malformed messages are skipped with a warning.
"""
function check_scan_timestamp(starttime, message; tol=120.0)
    parts = split(message*":::", ':')
    length(parts) < 4 && return
    ts_str = parts[4]
    isempty(ts_str) && return
    msg_ts = try
        datetime2unix(DateTime(ts_str, dateformat"yyyymmddTHHMMSSZ"))
    catch
        @warn "could not parse timestamp \"$ts_str\" from message \"$message\", " *
              "skipping scan-timestamp consistency check" _module=nothing _file=nothing
        return
    end
    delta = starttime - msg_ts
    abs(delta) <= tol && return
    throw(RecipeConsistencyError(
        "scan start mismatch: raw header starttime is " *
        "$(Dates.format(unix2datetime(starttime), "yyyymmddTHHMMSSZ")) " *
        "but targets message timestamp is $ts_str " *
        "(delta=$(round(delta, digits=1)) s)"))
end
