#!/bin/sh
for dev in $(upower -e | grep -v DisplayDevice); do
    name=$(basename "$dev")
    perc=$(upower -i "$dev" | awk '/percentage/ {print $2}' | tr -d '%')
    filled=$(expr "$perc" / 5)
    empty=$(expr 20 - "$filled")
    
    bar=""
    i=0
    while [ $i -lt $filled ]; do
        bar="${bar}█"
        i=$(expr $i + 1)
    done
    i=0
    while [ $i -lt $empty ]; do
        bar="${bar}░"
        i=$(expr $i + 1)
    done
    
    printf "%-50s %3s%% %s\n" "$name" "$perc" "$bar"
done

