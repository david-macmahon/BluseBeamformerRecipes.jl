using BeamformerRecipes
using YAML

"""
    cal_solution(redis, arrayname, unixtime) -> nants, nchan, ants, cals

Fetch the most recent telstate calibration solution for subarray `arrayname`
from `redis` as of `unixtime`.  `nants` and `nchan` are integers used in the
dimensioning of the data arrays, `ants` is a Vector of antenna names (in F
engine order), and `cals` is a `Dict{Symbol, Any}` suitable for splatting into
the keyword arguments of the `CalInfo` constructor.
"""
function cal_solution(redis, arrayname, unixtime)
    # zrevrangebyscore returns an OrderedSet
    rkeys = zrevrangebyscore(redis, "$arrayname:cal_solutions:index", unixtime, 0, "limit", 0, 1)
    if length(rkeys) == 0
        @warn "no cal solutions found on or before $unixtime, using fallback hack" _module=nothing _file=nothing
        rkeys = ["array_1:cal_solutions:20220117T035342Z"]
    end
    length(rkeys) <= 0 && error("no cal solutions found")
    length(rkeys)  > 1 && error("too many cal solutions found")
    @info "using cal solution $(rkeys[1])"
    strcals = hgetall(redis, rkeys[1])

    # Parse integers
    nants = parse(Int, strcals["nants"])
    nchan = parse(Int, strcals["nchan"])
    ants = YAML.load(strcals["antenna_list"])
    # TODO Fix upstream and in redis
    # Workaround for nants bug
    if nants > 64
        nants ÷= 8
    end

    # Create Arrays and copy data into them
    # TODO Fix cal_K type upstream and in redis
    if sizeof(strcals["cal_K"]) == nants * 2 #=npols=# * sizeof(Float64) * 2 #=complex=#
        cal_K = Array{ComplexF64}(undef, nants, 2)
    else
        cal_K = Array{Float64}(undef, nants, 2)
    end
    @assert sizeof(cal_K) == sizeof(strcals["cal_K"])
    unsafe_copyto!(pointer(cal_K), Ptr{eltype(cal_K)}(pointer(strcals["cal_K"])), length(cal_K))

    cal_B = Array{ComplexF64}(undef, nants, 2, nchan)
    @assert sizeof(cal_B) == sizeof(strcals["cal_B"])
    unsafe_copyto!(pointer(cal_B), Ptr{ComplexF64}(pointer(strcals["cal_B"])), length(cal_B))

    cal_G = Array{ComplexF64}(undef, nants, 2)
    @assert sizeof(cal_G) == sizeof(strcals["cal_G"])
    unsafe_copyto!(pointer(cal_G), Ptr{ComplexF64}(pointer(strcals["cal_G"])), length(cal_G))

    cal_all = Array{ComplexF64}(undef, nants, 2, nchan)
    @assert sizeof(cal_all) == sizeof(strcals["cal_all"])
    unsafe_copyto!(pointer(cal_all), Ptr{ComplexF64}(pointer(strcals["cal_all"])), length(cal_all))

    # Replace all NaN values with 0
    cal_K[isnan.(cal_K)] .= 0
    cal_B[isnan.(cal_B)] .= 0
    cal_G[isnan.(cal_G)] .= 0
    cal_all[isnan.(cal_all)] .= 0

    cals = Dict{Symbol, Any}()
    cals[:cal_K] = real(cal_K) * 1e9 # seconds to nanoseconds
    cals[:cal_B] = cal_B
    cals[:cal_G] = cal_G
    cals[:cal_all] = cal_all
    cals[:refant] = strcals["refant"]

    nants, nchan, ants, cals
end
