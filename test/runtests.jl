using BluseBeamformerRecipes
using BluseBeamformerRecipes: RecipeConsistencyError, check_nants,
    check_antenna_names, assert_nants_consensus, subarray_nants,
    check_scan_timestamp, value_histogram, slack_alert, targets2bfr,
    subarray2grh, cal_solution_key, cal_solution, SLACK_CHANNEL,
    SLACK_PROXY_CHANNEL
using Redis
using Test
using Dates

# Minimal in-memory redis substitute implementing just the subset of the
# Redis.jl API used by the consistency checks: hget, hgetall, lrange,
# zrevrangebyscore and publish.
mutable struct FakeRedis
    hashes::Dict{String,Dict{String,String}}
    lists::Dict{String,Vector{String}}
    zsets::Dict{String,Vector{Pair{Float64,String}}}
    published::Vector{Tuple{String,String}}
end
FakeRedis() = FakeRedis(Dict(), Dict(), Dict(), Tuple{String,String}[])

function Redis.hget(fr::FakeRedis, key, field)
    h = get(fr.hashes, String(key), nothing)
    h === nothing ? nothing : get(h, String(field), nothing)
end

function Redis.hgetall(fr::FakeRedis, key)
    h = get(fr.hashes, String(key), nothing)
    h === nothing ? Dict{AbstractString,AbstractString}() :
                    Dict{AbstractString,AbstractString}(h)
end

function Redis.lrange(fr::FakeRedis, key, start, stop)
    v = get(fr.lists, String(key), String[])
    n = length(v)
    n == 0 && return String[]
    s = start == 0 ? 1 : (start < 0 ? n + start + 1 : start + 1)
    e = stop == -1 ? n : (stop < 0 ? n + stop + 1 : stop + 1)
    (s < 1 || s > n || e < s) ? String[] : v[clamp(s,1,n):clamp(e,1,n)]
end

function Redis.zrevrangebyscore(fr::FakeRedis, key, maxscore, minscore, opts...)
    members = get(fr.zsets, String(key), Pair{Float64,String}[])
    sel = [p.second for p in members if minscore <= p.first <= maxscore]
    sort!(sel, rev=true)
    offset, count = 0, length(sel)
    for i in 1:3:length(opts)
        if opts[i] == "limit"
            offset = Int(opts[i+1])
            count = Int(opts[i+2])
        end
    end
    offset >= length(sel) && return String[]
    sel[offset+1 : min(offset + count, length(sel))]
end

function Redis.publish(fr::FakeRedis, channel, message)
    push!(fr.published, (String(channel), String(message)))
    length(fr.published)
end

# Helper: set the status hash NANTS value for a hostinst
function set_status!(fr, hostinst, fields)
    fr.hashes["bluse://$hostinst/status"] = Dict{String,String}(fields)
end

@testset "BluseBeamformerRecipes consistency checks" begin

    @testset "value_histogram" begin
        @test value_histogram(Dict(55 => 30, 62 => 34)) == "55 (n=30), 62 (n=34)"
        @test value_histogram(Dict(59 => 1)) == "59 (n=1)"
    end

    @testset "check_nants (Layer A)" begin
        calkey = "array_1:cal_solutions:20261124T022624Z"
        # Agreement (as in healthy sessions) passes:
        @test check_nants(62, 62, calkey) === nothing
        @test check_nants(55, 55, calkey) === nothing
        # Mismatch (raw header 55 vs recipe from 62-ant cal, the 2026-11-24
        # failure mode) throws:
        err = try
            check_nants(55, 62, calkey)
            nothing
        catch e
            e
        end
        @test err isa RecipeConsistencyError
        @test occursin("55", err.msg) && occursin("62", err.msg)
        @test occursin(calkey, err.msg)
    end

    @testset "check_antenna_names (Layer B)" begin
        # Identical sets pass:
        @test check_antenna_names("array_1", ["m000", "m001"],
                                  ["m001", "m000"]) === nothing
        # Different sets with same cardinality throw (name-level check):
        err = try
            check_antenna_names("array_1", ["m000", "m001"], ["m000", "m002"])
            nothing
        catch e
            e
        end
        @test err isa RecipeConsistencyError
        @test occursin("m001", err.msg) && occursin("m002", err.msg)
        # Different cardinality throws:
        @test_throws RecipeConsistencyError check_antenna_names(
            "array_1", ["m$i" for i in 0:61], ["m$i" for i in 0:54])
        # Empty antenna list (missing redis key) skips the check:
        @test check_antenna_names("array_1", ["m000"], String[]) === nothing
    end

    @testset "assert_nants_consensus (Layer C)" begin
        # Unanimity and single/empty inputs pass:
        @test assert_nants_consensus(Dict("blpn64/0" => 62), "array_1") === nothing
        @test assert_nants_consensus(Dict{String,Int}(), "array_1") === nothing
        @test assert_nants_consensus(
            Dict(h => 62 for h in ["blpn64/0", "blpn66/1"]), "array_1") === nothing
        # Disagreement throws with a terse summary:
        err = try
            assert_nants_consensus(
                Dict("blpn64/0" => 62, "blpn66/0" => 62, "blpn68/0" => 55),
                "array_1")
            nothing
        catch e
            e
        end
        @test err isa RecipeConsistencyError
        @test occursin("NANTS disagreement", err.msg)
        @test occursin("62 (n=2)", err.msg) && occursin("55 (n=1)", err.msg)
    end

    @testset "subarray_nants" begin
        fr = FakeRedis()
        set_status!(fr, "blpn64/0", Dict("NANTS" => "62"))
        set_status!(fr, "blpn66/0", Dict("NANTS" => " 62 "))
        set_status!(fr, "blpn68/0", Dict("NANTS" => "bogus"))
        set_status!(fr, "blpn70/0", Dict("DWELL" => "0"))  # no NANTS field
        m = subarray_nants(fr, ["blpn64/0", "blpn66/0", "blpn68/0", "blpn70/0",
                                "blpn72/0"])
        @test m == Dict("blpn64/0" => 62, "blpn66/0" => 62)
    end

    @testset "check_scan_timestamp (Layer D)" begin
        # 2026-11-24 02:26:24Z, the first scan of the bad session:
        msg = "targets:MeerKAT:array_1:20261124T022624Z"
        ts = datetime2unix(DateTime(2026, 11, 24, 2, 26, 24))
        # Fresh header (~1 s fast, as observed on healthy scans):
        @test check_scan_timestamp(ts + 0.8, msg) === nothing
        # Stale header 4.9 hours behind (the actual failure mode):
        err = try
            check_scan_timestamp(ts - 17640, msg)
            nothing
        catch e
            e
        end
        @test err isa RecipeConsistencyError
        @test occursin("20261124T022624Z", err.msg)
        @test occursin("-17640", err.msg)
        # Stale header 12 hours behind (the PKTSTART=0 case):
        @test_throws RecipeConsistencyError check_scan_timestamp(ts - 12*3600, msg)
        # Generous tolerance honoured:
        @test check_scan_timestamp(ts - 100, msg; tol=120) === nothing
        @test_throws RecipeConsistencyError check_scan_timestamp(ts - 100, msg; tol=60)
        # Malformed/short messages are skipped:
        @test check_scan_timestamp(ts, "targets:MeerKAT:array_1:") === nothing
        @test check_scan_timestamp(ts, "not-a-targets-message") === nothing
    end

    @testset "slack_alert format" begin
        fr = FakeRedis()
        slack_alert(fr, ":warning: test alert")
        @test length(fr.published) == 1
        channel, text = fr.published[1]
        @test channel == SLACK_PROXY_CHANNEL == "slack-messages"
        @test occursin("$(SLACK_CHANNEL):[", text)
        # "<channel>:[<timestring> - <name>] <message>" (coordinator format):
        m = match(r"^meerkat-obs-log:\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \S+) - (\S+)\] (.*)$", text)
        @test m !== nothing
        @test m[2] == "bfr5_generator"
        @test m[3] == ":warning: test alert"
    end

    @testset "cal_solution_key" begin
        fr = FakeRedis()
        key = "array_1:cal_solutions:index"
        fr.zsets[key] = [1795455312.0 => "array_1:cal_solutions:20261123T172200Z",
                         1795487241.0 => "array_1:cal_solutions:20261124T015853Z"]
        # Newest solution at or before the given time:
        @test cal_solution_key(fr, "array_1", 1795487241.0) ==
              "array_1:cal_solutions:20261124T015853Z"
        @test cal_solution_key(fr, "array_1", 1795455312.0) ==
              "array_1:cal_solutions:20261123T172200Z"
        # No solution available: hard error, NOT the old hardcoded
        # 20220117T035342Z fallback:
        err = try
            cal_solution_key(fr, "array_1", 1795000000.0)
            nothing
        catch e
            e
        end
        @test err isa RecipeConsistencyError
        @test occursin("no cal solutions found", err.msg)
    end

    @testset "cal_solution parsing" begin
        function make_cal_hash(nants_str, ants)
            nants = parse(Int, nants_str)
            nchan = 2
            zeros_bytes(n) = String(fill(0x00, n))
            Dict{String,String}(
                "nants" => nants_str, "nchan" => string(nchan),
                "antenna_list" => "[" * join(ants, ", ") * "]",
                "refant" => first(ants),
                "cal_K" => zeros_bytes(nants * 2 * 16),
                "cal_B" => zeros_bytes(nants * 2 * nchan * 16),
                "cal_G" => zeros_bytes(nants * 2 * 16),
                "cal_all" => zeros_bytes(nants * 2 * nchan * 16))
        end
        fr = FakeRedis()
        calkey = "array_1:cal_solutions:20261124T015853Z"
        fr.hashes[calkey] = make_cal_hash("3", ["m000", "m001", "m002"])
        nants, nchan, ants, cals = cal_solution(fr, calkey)
        @test nants == 3 && nchan == 2
        @test ants == ["m000", "m001", "m002"]
        @test size(cals[:cal_K]) == (3, 2)
        @test size(cals[:cal_B]) == (3, 2, 2)
        # Internally inconsistent cal (nants vs antenna_list):
        fr.hashes["array_1:cal_solutions:BAD"] = make_cal_hash("4", ["m000", "m001", "m002"])
        err = try
            cal_solution(fr, "array_1:cal_solutions:BAD")
            nothing
        catch e
            e
        end
        @test err isa RecipeConsistencyError
        @test occursin("internally inconsistent", err.msg)
    end

    @testset "subarray2grh (Layer C)" begin
        fr = FakeRedis()
        fr.lists["coordinator:allocated_hosts:array_1"] =
            ["blpn64/0", "blpn66/0", "blpn68/0"]

        # All hostinsts agree: first non-empty status hash wins, as before.
        set_status!(fr, "blpn64/0", Dict("NANTS" => "62"))
        set_status!(fr, "blpn66/0", Dict("NANTS" => "62"))
        set_status!(fr, "blpn68/0", Dict("NANTS" => "62"))
        grh = subarray2grh(fr, "array_1")
        @test grh[:nants] == 62

        # Disagreement (the 2026-11-24 failure mode: 34 stale, 30 fresh)
        # throws with the terse summary:
        set_status!(fr, "blpn68/0", Dict("NANTS" => "55"))
        err = try
            subarray2grh(fr, "array_1")
            nothing
        catch e
            e
        end
        @test err isa RecipeConsistencyError
        @test occursin("NANTS disagreement across 3 hostinsts", err.msg)
        @test occursin("55 (n=1), 62 (n=2)", err.msg)

        # No allocated hostinsts at all: empty header (unchanged behaviour).
        fr2 = FakeRedis()
        grh2 = subarray2grh(fr2, "array_1")
        @test isempty(grh2)

        # Status hashes present but without NANTS: warns and falls back to
        # first non-empty hash.
        fr3 = FakeRedis()
        fr3.lists["coordinator:allocated_hosts:array_1"] = ["blpn64/0"]
        fr3.hashes["bluse://blpn64/0/status"] = Dict{String,String}("OBSID" => "x")
        grh3 = subarray2grh(fr3, "array_1")
        @test grh3[:obsid] == "x"
    end

    @testset "targets2bfr refuses + slacks on inconsistency" begin
        fr = FakeRedis()
        fr.lists["coordinator:allocated_hosts:array_1"] =
            ["blpn64/0", "blpn66/0"]
        set_status!(fr, "blpn64/0", Dict("NANTS" => "62"))
        set_status!(fr, "blpn66/0", Dict("NANTS" => "55"))
        msg = "targets:MeerKAT:array_1:20261124T022624Z"
        # The RecipeConsistencyError propagates (listener logs it) ...
        err = try
            targets2bfr(fr, msg, mktempdir())
            nothing
        catch e
            e
        end
        @test err isa RecipeConsistencyError
        # ... and a Slack alert was published for it:
        @test length(fr.published) == 1
        channel, text = fr.published[1]
        @test channel == "slack-messages"
        @test occursin("refused to emit recipe for `$msg`", text)
        @test occursin("NANTS disagreement across 2 hostinsts", text)
    end

end
