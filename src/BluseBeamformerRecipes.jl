module BluseBeamformerRecipes

using BeamformerRecipes
using FringeExplorer
using RadioInterferometry
using EarthOrientation
using LinearAlgebra
using Dates
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

    # Create frequency array
    freqs=collect(range(fch1(grh), step=foff(grh), length=nchan))

    # Get boresight RA/Dec
    α = ra(grh)
    δ = dec(grh)

    # Get beam positions
    nrings = 4
    beam_positions = beamrings(α, δ, nrings=nrings)
    beam_names = ["B$(b)R$(r)" for r=1:nrings for b=1:6r]
    pushfirst!(beam_names, "BORESIGHT")
    nbeams = length(beam_names)

    # Get delays and delay rates each second for 300 seconds
    ntimes = 300
    delays = Array{Float64}(undef, nants, nbeams, ntimes)
    rates = Array{Float64}(undef, nants, nbeams, ntimes)

    Δt = 1.0
    times = collect(range(start, step=Δt, length=ntimes))

    jd = datetime2julian(unix2datetime(start))
    Δjd = 1/86400
    jds = collect(range(jd, step=Δjd, length=ntimes))

    # Use a single dut1 value for the entire scan
    jdmid = jd + Δjd * ntimes/2
    dut1 = EarthOrientation.getΔUT1(jdmid)

    # Get hour angles and declinations for each beam at start
    hdobs = radec2hadec(beam_positions, jd,
        latitude=telinfo.latitude,
        longitude=telinfo.longitude,
        altitude=telinfo.altitude,
        dut1=dut1, xp=0.0, yp=0.0
    )

    # Convert observed hours angles to "observed transit times" (transit at tobs=0)
    tobs = ha2t.(hdobs[1,:])
    dobs =       hdobs[2,:]

    # Create wdw_m and wdw matrices
    wdw_m = zeros(Float64, 2, 3)
    wdw = zeros(Float64, 2, nants)

    # Convert antpos into topocentric XYZ
    antpos = antpos_topo_xyz(telinfo)

    # Convert antpos into nanoseconds
    antpos ./= RadioInterferometry.CMPNS

    # For each time step
    for ti in 1:ntimes
        # For each beam
        for bi in 1:nbeams
            # Get dwd matrix for current time/beam
            td2wdw!(wdw_m, tobs[bi], dobs[bi])
            # Get delay and rate for each antenna
            mul!(wdw, wdw_m, antpos)
            # Store in delays and rates
            delays[:, bi, ti] .= wdw[1, :]
            rates[ :, bi, ti] .= wdw[2, :]
        end

        # Step tobs
        tobs .+ Δt
    end

    # Subtract boresight delay and rate from each antenna,beam
    delays .-= delays[:,1:1,:]
    rates  .-= rates[ :,1:1,:]

    BeamformerRecipe(
        diminfo=DimInfo(
            nants=nants,
            npol=2,
            nchan=nchan,
            nbeams=nbeams,
            ntimes=ntimes),
        telinfo=telinfo,
        obsinfo=ObsInfo(
            obsid=obsid(grh, telinfo.telescope_name),
            freq_array=freqs,
            phase_center_ra=α,
            phase_center_dec=δ,
            instrument_name=instrument(grh)
        ),
        calinfo=CalInfo(; cals...),
        beaminfo=BeamInfo(
            ras=beam_positions[1, :],
            decs=beam_positions[2, :],
            src_names=beam_names
        ),
        delayinfo=DelayInfo(
            delays=delays,
            rates=rates,
            time_array=times,
            jds=jds,
            dut1=dut1
        )
    )
end

end
