module BluseBeamformerRecipes

using BeamformerRecipes
using Redis
using Blio
using YAML

# Re-export all names from BeamformerRecipes
for name in names(BeamformerRecipes)
    @eval export $name
end

include("telinfo.jl")
include("cal_solution.jl")
include("guppiraw.jl")

"""
    BeamformerRecipes.BeamformerRecipe(rawname; redis, telinfo_file)

Create a BeamformerRecipe and populate the following fields:

- `DimInfo` (all but `nbeams` and `ntimes`)
- `TelInfo`
- `ObsInfo`
- `CalInfo`
"""
function BeamformerRecipes.BeamformerRecipe(
    rawname::AbstractString;
    redis::RedisConnection=RedisConnection(host="redishost"),
    telinfo_file::AbstractString=joinpath(ENV["HOME"], "telinfo.yml")
)
    # Read GuppiRaw.Header from `rawname`
    @info "reading header from $rawname"
    grh = open(io->read(io, GuppiRaw.Header), rawname)

    subname = subarray_name(grh)
    start = starttime(grh)

    # Read cal_solution from redis
    nants, nchan, ants, cals = cal_solution(redis, subname, start)

    # Load telinfo and then filter/reorder according to nants
    telinfo=TelInfo(telinfo_file)
    # Get indices of `ants` in telinfo.antenna_names
    idxs = indexin(ants, telinfo.antenna_names)
    # Filter/reorder antenna fields in telinfo
    telinfo.antenna_positions = telinfo.antenna_positions[:,idxs]
    telinfo.antenna_names = telinfo.antenna_names[idxs]
    telinfo.antenna_numbers = telinfo.antenna_numbers[idxs]
    telinfo.antenna_diameters = telinfo.antenna_diameters[idxs]

    BeamformerRecipe(
        diminfo=DimInfo(nants=nants, npol=2, nchan=nchan),
        telinfo=telinfo,
        obsinfo=ObsInfo(
            obsid=obsid(grh, telinfo.telescope_name),
            freq_array=collect(range(fch1(grh), step=foff(grh), length=nchan)),
            phase_center_ra=ra(grh),
            phase_center_dec=dec(grh),
            instrument_name=instrument(grh)
        ),
        calinfo=CalInfo(; cals...)
    )
end

end
