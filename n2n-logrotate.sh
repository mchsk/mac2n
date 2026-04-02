#!/bin/sh
# n2n log rotation — rotates logs over 5 MB, keeps 3 archives
for f in /var/log/n2n-*.log; do
    [ -f "$f" ] || continue
    s=$(stat -f%z "$f" 2>/dev/null || echo 0)
    [ "$s" -gt 5242880 ] || continue

    # Disk critically low — truncate without archiving
    avail_kb=$(df -k /var/log 2>/dev/null | awk 'NR==2{print $4}')
    if [ "${avail_kb:-0}" -lt 10240 ]; then
        : > "$f"
        continue
    fi

    i=3
    while [ "$i" -gt 1 ]; do
        j=$((i - 1))
        [ -f "${f}.${j}.gz" ] && mv -f "${f}.${j}.gz" "${f}.${i}.gz"
        i=$j
    done
    gzip -c "$f" > "${f}.1.gz" 2>/dev/null
    : > "$f"
done
