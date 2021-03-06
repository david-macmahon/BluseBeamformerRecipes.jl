using Blio

"""
    subarray_name(grh::GuppiRaw.Header)

Get subarray name from Header, default to "array_1" if missing.
"""
function subarray_name(grh::GuppiRaw.Header)
    get(grh, :subarray, "array_1")
end

"""
    starttime(grh::GuppiRaw.Header)

Calculate starttime from Header in seconds since the Unix epoch.
"""
function starttime(grh::GuppiRaw.Header)
    # Calc seconds per block
    secs_per_blk = grh[:tbin] * ntime(grh)

    # Calc seconds per PKTIDX
    secs_per_pktidx = secs_per_blk / grh[:piperblk]

    # Calc seconds from SYNCTIME to PKTSTART
    secs_since_synctime = grh[:pktstart] * secs_per_pktidx

    # Return seconds from UNIX epoch to PKTSTART
    grh[:synctime] + secs_since_synctime
end

"""
    obsid(grh::GuppiRaw.Header, telescope)

Get OBSID from `grh`, using `telescope` as the telescope component.
"""
function obsid(grh::GuppiRaw.Header, telescope)
    subname = subarray_name(grh)
    timestamp = Libc.strftime("%Y%m%dT%H%M%SZ", starttime(grh))
    join((telescope, subname, timestamp), ':')
end

"""
    obsid(grh::GuppiRaw.Header)

Get OBSID from `grh`.
"""
function obsid(grh::GuppiRaw.Header)
    telescope = lowercase(get(grh, :telescop, "MeerKAT"))
    obsid(grh, telescope)
end

"""
    instrument(grh::GuppiRaw.Header)

Get instrumwnt from `grh[:instrmnt]`, defaulting to "bluse" if missing.
"""
function instrument(grh::GuppiRaw.Header)
    get(grh, :instrmnt, "bluse")
end

"""
    fch1(grh::guppiraw.header)

Get frequency of first channel of entire band (not just grh's sub-band) in GHz.
"""
function fch1(grh::GuppiRaw.Header)
    (chanfreq(grh, 1) - grh[:schan] * grh[:chan_bw]) / 1e3
end

"""
    fch1(grh::guppiraw.header)

Get coarse channel frequency step size (aka width) in GHz.
"""
function foff(grh::GuppiRaw.Header)
    grh[:chan_bw] / 1e3
end

"""
    ra(grh::guppiraw.header)

Get right ascension from `grh` in radians.
"""
function ra(grh::GuppiRaw.Header)
    deg2rad(grh[:ra])
end

"""
    dec(grh::guppiraw.header)

Get declination from `grh` in radians.
"""
function dec(grh::GuppiRaw.Header)
    deg2rad(grh[:dec])
end
