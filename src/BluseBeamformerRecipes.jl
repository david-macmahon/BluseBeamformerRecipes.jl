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
include("redisguppi.jl")

"""
    BeamformerRecipe(grh, beam_names, beam_positions; redis, telinfo_file)

Create a BeamformerRecipe for the scan described by `grh` (a `GuppiRaw.Header`
object) with beams whose names are given by `beam_names` and whose positions are
given as `beam_positions`.  Ancillary info from `redis` and `telinfo_file` will
be used.

The following fields will be
populated:

- `DimInfo`
- `TelInfo`
- `ObsInfo`
- `CalInfo`
"""
function BeamformerRecipes.BeamformerRecipe(
    grh::GuppiRaw.Header, beam_names, beam_positions;
    redis::RedisConnection=RedisConnection(host="redishost"),
    telinfo_file::AbstractString=joinpath(ENV["HOME"], "telinfo.yml")
)
    # Get number of beams
    @assert length(beam_names) == size(beam_positions, 2) "beam names and positions size mismatch"
    nbeams = length(beam_names)

    subname = subarray_name(grh)
    tstart = starttime(grh)

    # Read cal_solution from redis
    nants, nchan, ants, cals = cal_solution(redis, subname, tstart)

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

    # Time step is 1 second (for now)
    Δt = 1.0
    Δjd = Δt/86400

    # Get delays and delay rates each Δt for "DWELL" (or 300) seconds
    ntimes = ceil(Int, get(grh, "DWELL", 300) / Δt)
    delays = Array{Float64}(undef, nants, nbeams, ntimes)
    rates = Array{Float64}(undef, nants, nbeams, ntimes)
    times = collect(range(tstart, step=Δt, length=ntimes))
    jdstart = datetime2julian(unix2datetime(tstart))
    jds = collect(range(jdstart, step=Δjd, length=ntimes))

    # Use a single dut1 value for the entire scan.  Use value from RAW header,
    # if present, otherwise use value from EarthOrientation for nearest midnight
    # to jdstart.
    jdmid = floor(jdstart - 0.5) + 0.5
    dut1 = get(grh, "UT1_UTC", EarthOrientation.getΔUT1(jdmid))

    # Get boresight RA/Dec
    α = ra(grh)
    δ = dec(grh)

    # Add bore sight position to "front" of beam_positions 
    beam_positions = hcat([α, δ], beam_positions)

    # Get hour angles and declinations for each beam at jdstart
    hdobs = radec2hadec(beam_positions, jdstart,
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
        tobs .+= Δt
    end

    # Subtract boresight delay and rate from each antenna,beam
    delays = delays[:, 2:end, :] .- delays[:,1:1,:]
    rates  = rates[ :, 2:end, :] .- rates[ :,1:1,:]

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

"""
    BeamformerRecipes.BeamformerRecipe(rawname; redis, telinfo_file, ring_arcsec)

Create a BeamformerRecipe for the scan corresponding to GUPPI RAW file `rawname`
using ancillary info from `redis` and `telinfo_file`.  One beam will be at bore
sight and 60 other beams will be arranged in four concentric rings with radii
`1:4 .* ring_arcsec`.  The following fields will be populated:

- `DimInfo` (all but `nbeams` and `ntimes`)
- `TelInfo`
- `ObsInfo`
- `CalInfo`
"""
function BeamformerRecipes.BeamformerRecipe(
    rawname::AbstractString;
    redis::RedisConnection=RedisConnection(host="redishost"),
    telinfo_file::AbstractString=joinpath(ENV["HOME"], "telinfo.yml"),
    ring_arcsec=10
)
    # Read GuppiRaw.Header from `rawname`
    @info "reading header from $rawname"
    grh = open(io->read(io, GuppiRaw.Header), rawname)

    # Get boresight RA/Dec
    α = ra(grh)
    δ = dec(grh)

    # Get beam positions
    nrings = 4
    beam_positions = beamrings(α, δ, nrings=nrings, dϕ=deg2rad(ring_arcsec/3600))

    # Get beam names
    src_name = get(grh, "SRC_NAME", "UNKNOWN")
    beam_names = ["$(src_name)_R$(r)B$(b)" for r=1:nrings for b=1:6r]
    pushfirst!(beam_names, src_name)

    BeamformerRecipe(grh, beam_names, beam_positions; redis, telinfo_file)
end

end
