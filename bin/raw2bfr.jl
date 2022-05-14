#!/bin/bash
#=
export JULIA_PROJECT=$(dirname $(dirname $(readlink -e "${BASH_SOURCE[0]}")))
exec julia --color=yes --startup-file=no "${BASH_SOURCE[0]}" "$@"
=#

# Example: Find all *.0000.raw files under /buf0ro and make beamformer recipe
#          files for them under /home/obs:
#
#     raw2bfr.jl /home/obs/bfr5 `find /buf0ro -name '*.0000.raw' -size +64M`
#
# If REDISHOST exists in ENV, the OBSID field of each RAW file will be used to
# lookup target selector targets in Redis.  If REDISHOST is not defined, then a
# test pattern consisting of "beam rings" will be used.  The radial spacing of
# the "beam rings" can be controlled by setting BFRING=<arcsec>.
#
# Example: Same as previous example, but separate rings by 1 arcminute rather
# than the default of 10 arcseconds:
#
#     BFRING=60 raw2bfr.jl /home/obs/bfr5 `find /buf0ro -name '*.0000.raw' -size +64M`

using BluseBeamformerRecipes
using Redis
using Blio

function mkoutdir(outdir::Nothing, rawname)
    # Split rawname into individual directory components
    rawdirs = splitpath(rawname)
    # If .../YYYYMMDD/NNNN/Unknown/GUPPI/foo.raw, Skip the Unknown/GUPPI parts
    if length(rawdirs) > 4 && rawdirs[end-2] == "Unknown" && rawdirs[end-1] == "GUPPI"
        joinpath(rawdirs[1:end-3]...)
    else
        joinpath(rawdirs[1:end-1]...)
    end
end

function mkoutdir(outdir, rawname)
    # Split rawname into individual directory components
    rawdirs = splitpath(rawname)
    # If .../YYYYMMDD/NNNN/Unknown/GUPPI/foo.raw, use the YYYYMMDD/NNNN parts
    if length(rawdirs) > 4 && rawdirs[end-2] == "Unknown" && rawdirs[end-1] == "GUPPI"
        joinpath(outdir, rawdirs[end-4], rawdirs[end-3])
    else
        outdir
    end
end

function mkbfr(::Nothing, outdir, rawname; ring_arcsec)
    bfr = BeamformerRecipe(rawname, ring_arcsec=ring_arcsec)

    h5dir = mkoutdir(outdir, rawname)
    h5base = replace(basename(rawname), r".\d\d\d\d.raw$"=>".bfr5")
    h5name = joinpath(h5dir, h5base)

    @info "$rawname => $h5name"
    if ispath(h5name)
        @warn "refusing to overwrite existing path" _module=nothing _file=nothing
    else
        isdir(h5dir) || mkpath(h5dir)
        to_hdf5(h5name, bfr)
    end
end

function mkbfr(redis, outdir, rawname; _...)
    grh = open(io->read(io, GuppiRaw.Header), rawname)
    if haskey(grh, :obsid)
        message = "targets:$(grh[:obsid])"
        BluseBeamformerRecipes.targets2bfr(grh, redis, message, outdir)
    else
        @warn "no OBSID found in $rawname" _module=nothing _file=nothing
    end
end

if isempty(ARGS) || (isdir(ARGS[1]) && length(ARGS) == 1)
    error("usage: $(PROGRAM_FILE) [OUTDIR] RAWFILE1 [RAWFILE2 [...]]")
else
    outdir = isdir(ARGS[1]) ? popfirst!(ARGS) : nothing

    # Check for REDISHOST in ENV
    if haskey(ENV, "REDISHOST")
        redis = RedisConnection(host=ENV["REDISHOST"])
    else
        redis = nothing
    end

    # Allow user to specify ring_arcsec via BFRING environment variable
    ring_arcsec = something(tryparse(Int, get(ENV, "BFRING", "10")), 10)

    for rawname in ARGS
        mkbfr(redis, outdir, rawname; ring_arcsec=ring_arcsec)
    end
end
