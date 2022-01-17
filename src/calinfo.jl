using BeamformerRecipes
using Redis

"""
    CalInfo(redis, unixtime)

Create a `CalInfo` instance from calibration data retreived from `redis` as of
`unixtime`.
"""
function CalInfo(redis::RedisConnection, unixtime)
    CalInfo()
end
