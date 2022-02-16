#!/bin/bash
#=
export JULIA_PROJECT=$(dirname $(dirname $(readlink -e "${BASH_SOURCE[0]}")))
exec julia --color=yes --startup-file=no "${BASH_SOURCE[0]}" "$@"
=#

using HDF5

function getantnames(bfr)
    h5open(bfr) do h5
        h5["telinfo/antenna_names"][]
    end
end

function mkobsinfo(io::IO, antennas, instrument="BLUSE")
    println(io, """
# Name of instrument
instrument: BLUSE

# Input map.  This lists which antenna-polarizations were connected to which
# correlator inputs.  For dual-polarization inputs, the two polarization for a
# given input are flattened into two sequential elements, with the "first"
# polarization of the input given before the "second" polarization.  The
# antenna-polarization for an input is given as a two element array.  The first
# element specifies the antenna.  This can be given as a string for antenna
# name or an integer for antenna number.  The second element specifies the
# polarization.  Valid values are L,R,X,Y (case-insensitive).  Polarizations
# must be specified for each input, even for single polarization instruments.
input_map: ["""
    )

    for a in antennas
        println(io, "  [$a, x], [$a, y],")
    end

    println(io, "]")
end

if abspath(PROGRAM_FILE) == @__FILE__
    for arg in ARGS
        if isdir(arg)
            # Assume/require all files in a subdir to have the same obsinfo
            bfrnames = filter(endswith(".bfr5"), readdir(arg, join=true))
            if isempty(bfrnames)
                @warn "$arg has no bfr5 files" _module=nothing _file=nothing
                continue
            end
            bfrname = bfrnames[1]
        else
            if !ispath(arg)
                @warn "$arg does not exist" _module=nothing _file=nothing
                continue
            end
            bfrname = arg
        end

        obsinfoname = joinpath(dirname(bfrname), "obsinfo.yml")
        @info "$bfrname => $obsinfoname"
        open(obsinfoname, "w") do obsinfo
            mkobsinfo(obsinfo, getantnames(bfrname))
        end
    end
end
