if status is-interactive
    # Commands to run in interactive sessions can go here
end

alias gpu-temp='watch "sensors | grep -A5000 -m1 -e 'amdgpu'"'
alias unset 'set --erase'

envsubst < ~/.env | sponge ~/.envdest1
cat ~/.envdest1 | tr -d '",' > ~/.envdest
rm ~/.envdest1
export $(envsubst < ~/.envdest)
rm ~/.envdest
