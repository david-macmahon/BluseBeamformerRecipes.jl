using BeamformerRecipes
using RadioInterferometry
using YAML

"""
    TelInfo(yaml::Dict{Symbol,Any})

Create a `TelInfo` instance based on `yaml` which was loaded from a "telinfo.yml"
file.
"""
function TelInfo(yaml::Dict{Symbol,Any})
    ti = BeamformerRecipes.TelInfo()
    # Populate the easy fields first
    ti.antenna_position_frame = string(get(yaml, :antenna_position_frame, nothing))
    ti.latitude = dms2d(get(yaml, :latitude, NaN))
    ti.longitude = dms2d(get(yaml, :longitude, NaN))
    ti.altitude = Float64(get(yaml, :altitude, NaN))
    ti.telescope_name = string(get(yaml, :telescope_name, "Unknown"))

    # Now do antenna specific fields
    ants = yaml[:antennas]
    diam = get(yaml, :antenna_diameter, 0.0)
    ti.antenna_names = map(a->string(a[:name]), ants)
    ti.antenna_numbers = map(a->Int(a[:number]), ants)
    ti.antenna_positions = mapreduce(a->convert(Vector{Float64}, a[:position]), hcat, ants)
    ti.antenna_diameters = map(a->Float64(get(a, :diameter, diam)), ants)

    # Validate that antenna positions are 3 dimensional
    @assert size(ti.antenna_positions, 1) == 3 "antenna positions are not 3D"

    ti
end

"""
    TelInfo(yaml::Dict{Symbol,Any})

Create a `TelInfo` instance based on a "telinfo.yml" file named by `yaml`.
"""
function TelInfo(yaml::AbstractString)
    TelInfo(YAML.load_file(yaml, dicttype=Dict{Symbol,Any}))
end
