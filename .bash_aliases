alias dockerwatch="watch docker ps --format \"'table {{.ID}}\t{{.Names}}\t{{.Networks}}\t{{.State}}\t{{.Status}}'\""
alias dockerstopallcontainers="docker stop \$(docker ps --format {{.ID}})"
alias backgroundremover='docker run -it --rm -v "$(pwd):/tmp" bgremover:latest'
