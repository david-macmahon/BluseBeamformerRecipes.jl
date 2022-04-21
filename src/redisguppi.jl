using Redis
using Blio

"""
    redis2grh(redis, key)

Return a GUPPI RAW header for HPGUPPI DAQ status buffer stored in redis hash
having key `key`.
"""
function redis2grh(redis, key)
    redishash = hgetall(redis, key)
    # Currently, Blio can only create a GuppiRaw.Header from a file, so we
    # have to create a GUPPI RAW header in a temporary file using key-value
    # pairs from the redis hash.
    mktemp() do path, grhio
        for (k,v) in redishash
            write(grhio, rpad(k,  8)) # 8 + 2 + 70 = 80
            write(grhio, "= ")
            write(grhio, rpad(v, 70))
        end
        write(grhio, rpad("END", 80))
        # Blio requires minimum file size :P
        write(grhio, " " ^ (80*256))
        seekstart(grhio)
        read(grhio, GuppiRaw.Header, skip_padding=false)
    end
end

"""
    hostinst2grh(redis, hostinst; domain="bluse")

Return a GUPPI RAW header for HPGUPPI DAQ status buffer stored in redis hash for
given `domain` and `hostinst`.  Retrieves redis hash for
`\$domain://\$hostinst/status`.
"""
function hostinst2grh(redis, hostinst; domain="bluse")
    redis2grh(redis, "$domain://$hostinst/status")
end

"""
    host2grh(redis, host, instance=0; domain="bluse")

Return a GUPPI RAW header for HPGUPPI DAQ status buffer stored in redis hash for
given `domain`, `host`, and `instance`.  Retrieves redis hash for
`\$domain://\$host/\$instance/status`.
"""
function host2grh(redis, hostname, instance=0; domain="bluse")
    hostinst2grh(redis, "$hostname/$instance", domain=domain)
end

"""
    subarray2grh(redis, subarray; domain="bluse")

Return a GUPPI RAW header for HPGUPPI DAQ status buffer stored in redis hash for
a host/instance that is present in `coordinator:allocated_hosts:\$subarray`.
First host/instance in the returned list for which a corresponding status hash
exists will be used.
"""
function subarray2grh(redis, subarray; domain="bluse")
    hostinsts = lrange(redis, "coordinator:allocated_hosts:$subarray", 0, -1)
    for hi in hostinsts
        grh = hostinst2grh(redis, hi, domain=domain)
        isempty(grh) || return grh
    end
    # Nothing found
    return GuppiRaw.Header()
end
