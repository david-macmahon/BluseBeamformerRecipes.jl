module BluseBeamformerRecipes

using BeamformerRecipes

# Re-export all names from BeamformerRecipes
for name in names(BeamformerRecipes)
    @eval export $name
end

include("telinfo.jl")

function caldata(redis, arrayname, unixtime)
    # zrevrangebyscore returns an OrderedSet
    hkeys = zrevrangebyscore(redis, "$arrayname:cal_solutions:index", unixtime, 0, "limit", 0, 1)
    length(hkeys) != 1 && return nothing
    hgetall(redis, hkeys[1])
end

end
