alias dockerwatch="watch docker ps --format \"'table {{.ID}}\t{{.Names}}\t{{.Networks}}\t{{.State}}\t{{.Status}}'\""
alias dockerstopallcontainers="docker stop \$(docker ps --format {{.ID}})"
alias nvimdiff="nvim -d"
alias upower-bars='watch ~/Documents/Scripts/upower-bars.sh'
